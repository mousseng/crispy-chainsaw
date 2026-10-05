--[[
* component registry: settings, layout, drawing and mouse routing.
*
* components are listed, with their settings defaults, in components/list.lua.
* each is a module components/<name>.lua, required the first time the
* component is enabled and dropped again when it's disabled, so a disabled
* component costs nothing. the module returns:
*
*   draw      fn(r, ctx, x, y) -> w, h   draws at screen (x, y); returns size
*   update    fn(ctx, dt)                optional; game state, before draw
*   measure   fn(ctx) -> w, h            optional; size this frame, before
*                                        placing. without it placement uses
*                                        last frame's size, so a component
*                                        that appears or resizes is misplaced
*                                        for one frame. may also return x, y
*                                        to be drawn there this frame instead
*                                        of where its settings put it (kept on
*                                        screen, and ignored while dragged).
*   mouse     fn(ctx, ev, x, y, e)       optional; ev = 'ldown' | 'lup' | 'rdown'
*                                        | 'rup' | 'wheel', x/y relative to the
*                                        component. return true to consume, or
*                                        on 'ldown' 'drag' to consume it and
*                                        start moving the component (as when
*                                        unlocked) until the button is let go.
*   packet_in fn(ctx, e)                 optional; every incoming packet (ashita's
*                                        packet_in event), even while hidden.
*                                        check e.id first; this runs a lot.
*   command   fn(ctx, args) -> handled, message
*                                        optional; `/linhud <name> ...` args the
*                                        hud doesn't handle itself. settings
*                                        are saved after a handled command.
*   destroy   fn(ctx)                    optional; called before the module is
*                                        dropped (disabled, reloaded, failed)
*
* every call into a component is guarded: if one raises an error, the
* component is shut off (hud.on_error reports it) and the rest of the hud
* carries on. `enable` or `reload` clears the failure and tries again.
*
* ctx is a per-component table: { name, settings, scale, x, y, w, h, hover,
* screen_w, screen_h, mouse_x, mouse_y } (mouse in screen pixels).
* components may keep their own fields on it; it is replaced on each load.
* ctx.modal is read back: a component sets it while it has something open
* (a popup menu) that every button press should go to, wherever it lands, so
* the popup can be used outside the component's own area and a click
* elsewhere closes it instead of reaching the game or another component.
* ctx.settings is rebound when ashita reloads settings (e.g. on character
* switch), so components must read it through ctx each time, never cache it.
*
* positions are stored as an anchor (one of nine screen points) plus an offset
* in logical pixels, so the hud stays in place across resolution changes. size
* is whatever the component drew last frame.
*
* hiding: the addon passes hud.frame the client's ui state (game/client.lua:
* chat expanded, map open, ...). settings.hide says which conditions hide the
* hud; a component's own `hide` table overrides single conditions. hidden
* components vanish at once (so they never sit on top of the game's own
* interface) and fade back in over settings.fade_in seconds. while hidden they
* skip update and draw and don't take the mouse, but stay loaded and keep
* receiving packets.
*
* toggling: a component turned on fades in over settings.fade_in seconds; one
* turned off fades out over settings.fade_out, still updating and drawing but
* not taking the mouse or commands, and is dropped once it's gone. turning it
* back on mid-fade reverses from where it is. one turned off while hidden, or
* by a settings reload, is dropped at once.
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

local components = {}; -- { name, defaults, mod, ctx, failed, alpha, shown, closing }, in paint order
local by_name = {};
local settings = nil;  -- the addon settings table (settings.components[name])
local screen_w, screen_h = 0, 0;

local unlocked = false;
local drag = nil;      -- { c, dx, dy, x, y } while moving a component
local captured = {};   -- button -> component that consumed its down event
local mouse_x, mouse_y = -1, -1;

hud.on_save = nil;     -- set by the addon; called after layout changes
hud.on_error = nil;    -- set by the addon; fn(name, what, err, trace) when a component fails

--[[ registration ]]--

local function new_ctx(c)
    return { name = c.name, settings = c.ctx and c.ctx.settings, x = 0, y = 0, w = 0, h = 0, hover = false };
end

---@param name string component name: its module, settings key and command name
---@param defaults table|nil its settings defaults
function hud.register(name, defaults)
    -- alpha starts at 0 so the hud fades in when first shown (e.g. after login).
    local c = { name = name, defaults = defaults or {}, mod = nil, failed = nil, alpha = 0, shown = false, closing = false };
    c.ctx = new_ctx(c);
    components[#components + 1] = c;
    by_name[name] = c;
end

---defaults for every registered component, for settings.load.
function hud.defaults()
    local out = T{};
    for _, c in ipairs(components) do
        local d = T{ enabled = true, anchor = 'topleft', x = 100, y = 100, grow_x = 'auto', grow_y = 'auto', hide = T{} };
        for k, v in pairs(c.defaults) do d[k] = v; end
        out[c.name] = d;
    end
    return out;
end

---points every component at the given settings table. call after load and
---whenever the settings library reloads.
function hud.bind(s)
    settings = s;
    for _, c in ipairs(components) do
        c.ctx.settings = s.components[c.name];
    end
    drag, captured = nil, {};
end

function hud.get(name)
    return by_name[name];
end

---@return table[] { name, enabled, loaded, failed } per component
function hud.list()
    local out = {};
    for _, c in ipairs(components) do
        out[#out + 1] = {
            name = c.name, enabled = c.ctx.settings and c.ctx.settings.enabled,
            loaded = c.mod ~= nil, failed = c.failed,
        };
    end
    return out;
end

--[[ loading and guarding ]]--

local traceback = debug.traceback;
local err_trace = nil; -- traceback of the last error caught by guard()

local function handler(err)
    err_trace = traceback(tostring(err), 2);
    return err;
end

---drops the component's module, so the next load starts from a clean slate.
local function unload(c)
    if (c.mod ~= nil and c.mod.destroy ~= nil) then
        xpcall(c.mod.destroy, handler, c.ctx); -- nothing to do if this fails too
    end
    c.mod = nil;
    package.loaded['components.' .. c.name] = nil;
    for k, v in pairs(captured) do
        if (v == c) then captured[k] = nil; end
    end
    if (drag ~= nil and drag.c == c) then drag = nil; end
    c.ctx = new_ctx(c);
    c.alpha, c.closing = 0, false; -- fades in when next loaded
end

---shuts a component off after an error until it's re-enabled or reloaded.
local function fail(c, what, err)
    c.failed = ('%s: %s'):format(what, tostring(err));
    local trace = err_trace or tostring(err);
    err_trace = nil;
    unload(c);
    if (hud.on_error) then hud.on_error(c.name, what, tostring(err), trace); end
end

---@return boolean ok, any a, any b the call's first two results when ok
local function guard(c, what, fn, ...)
    local ok, a, b, x, y = xpcall(fn, handler, ...);
    if (not ok) then
        fail(c, what, a);
        return false;
    end
    return true, a, b, x, y;
end

---requires the component's module if it isn't loaded yet.
---@return boolean loaded
local function load(c)
    if (c.mod ~= nil) then return true; end
    if (c.failed ~= nil) then return false; end
    local ok, mod = guard(c, 'load', require, 'components.' .. c.name);
    if (not ok) then return false; end
    if (type(mod) ~= 'table' or type(mod.draw) ~= 'function') then
        fail(c, 'load', 'module must return a table with a draw function');
        return false;
    end
    c.mod = mod;
    return true;
end

---clears a failure and drops the module so it's required afresh on the next
---frame (picking up edits to its file).
function hud.reload(name)
    local c = by_name[name];
    if (c == nil) then return false; end
    unload(c);
    c.failed = nil;
    return true;
end

function hud.set_enabled(name, on)
    local c = by_name[name];
    if (c == nil or c.ctx.settings == nil) then return false; end
    c.ctx.settings.enabled = on;
    if (on) then
        c.failed, c.closing = nil, false; -- mid-fade-out, it fades back in from there
    elseif (c.mod ~= nil and c.shown and (settings.fade_out or 0) > 0) then
        c.closing = true; -- hud.frame fades it out, then unloads it
        c.shown, c.ctx.modal = false, nil;
        if (drag ~= nil and drag.c == c) then drag = nil; end
    else
        unload(c);
    end
    if (hud.on_save) then hud.on_save(); end
    return true;
end

---sets a global hide condition, or with name a component's override of it
---(on = nil clears the override, back to the global setting).
---@return boolean ok
function hud.set_hide(name, cond, on)
    if (settings == nil) then return false; end
    if (name == nil) then
        settings.hide[cond] = on;
    else
        local c = by_name[name];
        if (c == nil or c.ctx.settings == nil) then return false; end
        c.ctx.settings.hide = c.ctx.settings.hide or T{};
        c.ctx.settings.hide[cond] = on;
    end
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

---clamps a component's position on one axis: one that fits stays wholly on
---screen, and one larger than the screen keeps the screen covered.
local function clamp(v, len, screen)
    local lo, hi = 0, screen - len;
    if (hi < lo) then lo, hi = hi, lo; end
    return math.max(lo, math.min(v, hi));
end

---@param x number|nil where the component asked to be this frame, if anywhere
local function place(c, scale, x, y)
    local s, ctx = c.ctx.settings, c.ctx;
    if (drag ~= nil and drag.c == c) then
        return drag.x, drag.y;
    end
    if (x == nil) then
        local a = ANCHORS[s.anchor] or ANCHORS.topleft;
        local px, py = pivot(s, a);
        x = screen_w * a[1] + s.x * scale - ctx.w * px;
        y = screen_h * a[2] + s.y * scale - ctx.h * py;
    end
    -- keep it on screen (e.g. after a resolution change)
    x = clamp(x, ctx.w, screen_w);
    y = clamp(y, ctx.h, screen_h);
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

---stores a component's position as (x, y) at size (w, h), as if dragged
---there; for one resizing itself around a point. ctx keeps describing the
---frame on screen.
function hud.move(name, x, y, w, h)
    local c = by_name[name];
    if (c == nil or c.ctx.settings == nil or theme.active() == nil) then return; end
    local ctx = c.ctx;
    local ow, oh = ctx.w, ctx.h;
    ctx.w, ctx.h = w, h;
    commit(c, x, y, theme.active().scale);
    ctx.w, ctx.h = ow, oh;
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

---one component's frame; bails out at the first error (the component has been
---shut off by then).
local function draw_component(r, c, dt, scale)
    local mod, ctx = c.mod, c.ctx;
    ctx.scale, ctx.screen_w, ctx.screen_h = scale, screen_w, screen_h;
    ctx.mouse_x, ctx.mouse_y = mouse_x, mouse_y;
    if (mod.update and not guard(c, 'update', mod.update, ctx, dt)) then return; end
    local mx, my;
    if (mod.measure) then
        local ok, w, h;
        ok, w, h, mx, my = guard(c, 'measure', mod.measure, ctx);
        if (not ok) then return; end
        ctx.w, ctx.h = w or 0, h or 0;
    end
    local x, y = place(c, scale, mx, my);
    ctx.x, ctx.y = x, y;
    local depth = r.depth();
    local ok, w, h = guard(c, 'draw', mod.draw, r, ctx, x, y);
    if (not ok) then
        r.restore(depth); -- whatever it drew before failing stays for this frame
        return;
    end
    ctx.w, ctx.h = w or 0, h or 0;
    ctx.hover = mouse_x >= x and mouse_x < x + ctx.w and mouse_y >= y and mouse_y < y + ctx.h;
end

local unlock_label = {}; -- component name -> text object, created on demand

---whether any active condition hides the component: its own `hide` entry for
---the condition if it has one, else the global setting.
local conds = nil; -- the condition names, from the first state seen

local function hidden(c, state)
    if (state == nil) then return false; end
    if (conds == nil) then
        -- once: moonjit can't compile pairs(), and this runs every frame
        conds = {};
        for cond in pairs(state) do conds[#conds + 1] = cond; end
    end
    local own, global = c.ctx.settings.hide, settings.hide;
    for i = 1, #conds do
        local cond = conds[i];
        if (state[cond]) then
            local h = own and own[cond];
            if (h == nil) then h = global and global[cond]; end
            if (h) then return true; end
        end
    end
    return false;
end

---updates and draws every enabled component.
---@param r table render module
---@param dt number seconds since last frame
---@param sw number screen width
---@param sh number screen height
---@param text table|nil text module (for unlock-mode labels)
---@param state table|nil condition -> active (see game/client.lua)
function hud.frame(r, dt, sw, sh, text, state)
    if (settings == nil or theme.active() == nil) then return; end
    screen_w, screen_h = sw, sh;
    local scale = theme.active().scale;

    local fade_step = (settings.fade_in or 0) > 0 and dt / settings.fade_in or 1;
    local fade_out_step = (settings.fade_out or 0) > 0 and dt / settings.fade_out or 1;
    for _, c in ipairs(components) do
        if (not c.ctx.settings.enabled) then
            if (c.closing and not hidden(c, state)) then
                -- toggled off: fade out, then drop it
                c.alpha = c.alpha - fade_out_step;
                if (c.alpha <= 0) then
                    unload(c);
                else
                    r.set_base_opacity(c.alpha);
                    draw_component(r, c, dt, scale);
                    r.set_base_opacity(1);
                    c.ctx.hover = false;
                end
            elseif (c.mod ~= nil) then
                -- disabled by a settings reload (e.g. character switch), or
                -- hidden mid-fade-out
                unload(c);
            end
        elseif (not load(c)) then
            c.shown = false;
        elseif (hidden(c, state)) then
            c.shown, c.alpha, c.ctx.hover = false, 0, false;
            c.ctx.modal = nil;
        else
            c.shown = true;
            c.alpha = math.min(1, c.alpha + fade_step);
            r.set_base_opacity(c.alpha);
            draw_component(r, c, dt, scale);
            r.set_base_opacity(1);
        end
    end

    -- move mode: outline everything so empty-looking components can be found.
    if (unlocked) then
        for _, c in ipairs(components) do
            local ctx = c.ctx;
            if (c.shown and c.mod ~= nil and ctx.w > 0) then
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
                if (c.shown and c.mod ~= nil and ctx.w > 0) then
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
        if (c.shown and c.mod ~= nil and c.ctx.modal) then return c; end
    end
    for i = #components, 1, -1 do
        local c = components[i];
        local ctx = c.ctx;
        if (c.shown and c.mod ~= nil and ctx.w > 0
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
            drag.x = clamp(e.x - drag.dx, drag.c.ctx.w, screen_w);
            drag.y = clamp(e.y - drag.dy, drag.c.ctx.h, screen_h);
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
            if (c.mod ~= nil and c.mod.mouse) then
                guard(c, 'mouse', c.mod.mouse, c.ctx, ev, e.x - c.ctx.x, e.y - c.ctx.y, e);
            end
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

    if (c.mod.mouse == nil) then return; end
    local ok, consumed = guard(c, 'mouse', c.mod.mouse, c.ctx, ev, e.x - c.ctx.x, e.y - c.ctx.y, e);
    if (ok and consumed == 'drag' and ev == 'ldown') then
        drag = { c = c, dx = e.x - c.ctx.x, dy = e.y - c.ctx.y, x = c.ctx.x, y = c.ctx.y };
        e.blocked = true;
    elseif (ok and consumed) then
        if (UP_OF[ev] ~= nil) then captured[UP_OF[ev]] = c; end
        e.blocked = true;
    end
end

--[[ commands ]]--

---passes a command to the component (which must be enabled, so it's loaded).
---@return boolean handled
---@return string|nil message to show
function hud.command(name, args)
    local c = by_name[name];
    if (c == nil or c.mod == nil or c.closing or c.mod.command == nil) then return false; end
    local ok, handled, message = guard(c, 'command', c.mod.command, c.ctx, args);
    if (ok and handled and hud.on_save) then hud.on_save(); end
    return ok and handled or false, message;
end

--[[ packets ]]--

---routes ashita's packet_in event to loaded components that handle packets.
function hud.packet_in(e)
    for _, c in ipairs(components) do
        local mod = c.mod;
        if (mod ~= nil and mod.packet_in ~= nil) then
            guard(c, 'packet_in', mod.packet_in, c.ctx, e);
        end
    end
end

--[[ lifecycle ]]--

function hud.shutdown()
    for _, c in ipairs(components) do
        if (c.mod ~= nil) then unload(c); end
    end
end

return hud;
