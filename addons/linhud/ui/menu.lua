--[[
* popup menu with submenus, for right-click actions.
*
* a component owns one, opens it with a list of entries, and while it's open:
* draws it last thing in its draw, sets ctx.modal (so every click reaches it,
* see ui/hud.lua) and hands it mouse events before handling them itself.
*
* entries: { label = 'Equip', action = fn }       runs fn and closes
*          { label = 'Move', items = { ... } }     opens a submenu on hover
*          { label = '...', disabled = true }      shown dimmed, does nothing
*          { sep = true }                          a divider
*
* labels are gdifonts text made when a menu (or submenu) opens and dropped
* when it closes.
--]]

local text  = require('ui.text');
local theme = require('ui.theme');

local menu = {};
menu.__index = menu;

-- logical pixels
local ROW_H, SEP_H, PAD_X, PAD_Y, ARROW_W, MIN_W = 20, 7, 10, 4, 14, 96;
local LABEL = { size = 12, bold = false };

function menu.new()
    return setmetatable({ levels = {}, x = 0, y = 0 }, menu);
end

local function new_level(items)
    local lv = { items = items, labels = {}, x = 0, y = 0, w = 0, h = 0, hover = nil, open = nil, placed = false };
    for i, it in ipairs(items) do
        if (not it.sep) then
            local opts = { text = it.label };
            for k, v in pairs(LABEL) do opts[k] = v; end
            lv.labels[i] = text.new(opts);
        end
    end
    return lv;
end

---opens items at screen (x, y), replacing anything already open.
function menu:open(items, x, y)
    self.levels = { new_level(items) };
    self.x, self.y = x, y;
end

function menu:close()
    self.levels = {};
end

function menu:is_open()
    return #self.levels > 0;
end

--[[ layout ]]--

local function measure(lv, s)
    local w, h, sub = 0, PAD_Y * 2, false;
    for i, it in ipairs(lv.items) do
        if (it.sep) then
            h = h + SEP_H;
        else
            w = math.max(w, (lv.labels[i]:size()));
            h = h + ROW_H;
            if (it.items) then sub = true; end
        end
    end
    lv.w = math.max(MIN_W * s, w + PAD_X * 2 * s + (sub and ARROW_W * s or 0));
    lv.h = h * s;
end

---the row at screen y, and its top.
local function row_at(lv, y, s)
    local ry = lv.y + PAD_Y * s;
    for i, it in ipairs(lv.items) do
        local rh = (it.sep and SEP_H or ROW_H) * s;
        if (y >= ry and y < ry + rh) then
            return (not it.sep) and i or nil, ry;
        end
        ry = ry + rh;
    end
    return nil;
end

local function row_top(lv, n, s)
    local ry = lv.y + PAD_Y * s;
    for i = 1, n - 1 do
        ry = ry + (lv.items[i].sep and SEP_H or ROW_H) * s;
    end
    return ry;
end

local function inside(lv, x, y)
    return x >= lv.x and x < lv.x + lv.w and y >= lv.y and y < lv.y + lv.h;
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(v, hi));
end

---the deepest open level under (x, y), and its index.
local function level_at(self, x, y)
    for i = #self.levels, 1, -1 do
        local lv = self.levels[i];
        if (inside(lv, x, y)) then return lv, i; end
    end
    return nil;
end

---follows the mouse: highlights the row under it and opens or closes
---submenus to match. moving off the menu leaves things as they are, so the
---cursor can cross a gap on its way into a submenu.
local function track(self, mx, my, s, sw, sh)
    local lv, li = level_at(self, mx, my);
    for _, l in ipairs(self.levels) do l.hover = nil; end
    if (lv == nil) then return; end

    local row = row_at(lv, my, s);
    lv.hover = row;
    if (row == lv.open) then return; end

    for i = #self.levels, li + 1, -1 do self.levels[i] = nil; end
    lv.open = nil;
    local it = row and lv.items[row];
    if (it ~= nil and it.items ~= nil and not it.disabled) then
        local sub = new_level(it.items);
        measure(sub, s);
        sub.x = lv.x + lv.w - 2 * s;
        if (sub.x + sub.w > sw) then sub.x = lv.x - sub.w + 2 * s; end
        sub.y = clamp(row_top(lv, row, s) - PAD_Y * s, 0, sh - sub.h);
        sub.placed = true;
        self.levels[li + 1] = sub;
        lv.open = row;
    end
end

--[[ drawing ]]--

---draws the menu if it's open. call at the end of the owner's draw.
function menu:draw(r, ctx)
    if (#self.levels == 0) then return; end
    local s, c = ctx.scale, theme.color;
    local sw, sh = ctx.screen_w, ctx.screen_h;

    local root = self.levels[1];
    if (not root.placed) then
        measure(root, s);
        root.x = clamp(self.x, 0, sw - root.w);
        root.y = clamp(self.y, 0, sh - root.h);
        root.placed = true;
    end
    track(self, ctx.mouse_x, ctx.mouse_y, s, sw, sh);

    for _, lv in ipairs(self.levels) do
        r.nineslice('panel_shadow', lv.x, lv.y, lv.w, lv.h, c('shadow'));
        r.nineslice('panel', lv.x, lv.y, lv.w, lv.h, c('popup_bg'));
        r.nineslice('panel_border', lv.x, lv.y, lv.w, lv.h, c('panel_border'));

        local ry = lv.y + PAD_Y * s;
        for i, it in ipairs(lv.items) do
            if (it.sep) then
                r.rect(lv.x + PAD_X * s, ry + math.floor(SEP_H * 0.5 * s), lv.w - PAD_X * 2 * s, 1, c('panel_border'));
                ry = ry + SEP_H * s;
            else
                local rh = ROW_H * s;
                if ((i == lv.hover or i == lv.open) and not it.disabled) then
                    r.rect(lv.x + 3 * s, ry, lv.w - 6 * s, rh, c('hover'));
                end
                if (it.items) then
                    r.sprite('arrow_party', lv.x + lv.w - (PAD_X + 2) * s, ry + rh * 0.5, c(it.disabled and 'text_dim' or 'text'), 0.7);
                end
                local label = lv.labels[i];
                local _, th = label:size();
                label:draw(lv.x + PAD_X * s, ry + (rh - th) * 0.5, c(it.disabled and 'text_dim' or 'text'));
                ry = ry + rh;
            end
        end
    end
end

--[[ mouse ]]--

---@param ev string hud mouse event
---@param x number screen x
---@param y number screen y
---@return string|nil 'used' (the menu took it), 'closed' (a press outside
---closed it; the owner may still act on the press), or nil when not open
function menu:mouse(ev, x, y, s)
    if (#self.levels == 0) then return nil; end
    local lv = level_at(self, x, y);
    if (lv == nil) then
        if (ev == 'ldown' or ev == 'rdown') then
            self:close();
            return 'closed';
        end
        return 'used';
    end
    if (ev ~= 'ldown') then return 'used'; end

    local row = row_at(lv, y, s);
    local it = row and lv.items[row];
    if (it ~= nil and it.action ~= nil and not it.disabled) then
        self:close();
        it.action();
    end
    return 'used';
end

return menu;
