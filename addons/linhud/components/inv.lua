--[[
* inventory: every bag's items as a grid of icons, a tab per group of bags
* (as xitools groups them), with gil and space used along the bottom.
*
* hovering an item shows its description; right-clicking it opens a menu of
* what can be done with it: use, trade, equip, move to another bag, drop.
* the wheel scrolls when a tab holds more than fits.
*
* `unified` (the default) lists a tab's bags as one sorted grid; off, each
* bag gets its own heading and grid.
*
* drawn in passes, so however many items are showing it's a few draw calls:
* every cell, then every icon (one texture, ui/icons.lua), then every stack
* count, then the gdifonts text (tab names, headings).
--]]

local bit       = require('bit');
local inventory = require('game.inventory');
local icons     = require('ui.icons');
local menu      = require('ui.menu');
local text      = require('ui.text');
local theme     = require('ui.theme');

local band = bit.band;

local inv = {}; -- settings defaults: components/list.lua

-- layout, logical px
local PAD, TAB_H, TAB_GAP, GAP = 8, 20, 14, 6;
local CELL, ICON, HEAD_H, SECTION_GAP = 36, 32, 18, 6;
local FOOT_H, BAR_W = 18, 3;
local MIN_COLS, MAX_COLS, MIN_ROWS, MAX_ROWS = 4, 20, 2, 20;

-- bags items can be moved to, in menu order.
local MOVE_TO = { 0, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16 };
local WARDROBE = inventory.GEAR_ONLY;
local INVENTORY, TEMPORARY = 0, 3;

local tab = 1;
local scroll = 0; -- logical px

-- the grid, rebuilt when the items or the view change.
local built_key = nil;
local cell_item, cell_x, cell_y, ncells = {}, {}, {}, 0; -- logical px from the content's top-left
local heads = {}; -- { bag, y }
local content_h = 0;
local used, capacity = 0, 0;

-- what was drawn last frame, for the mouse: tab label spans and visible cells (screen px).
local tab_x0, tab_x1, tab_y0, tab_y1 = {}, {}, 0, 0;
local hit_item, hit_x, hit_y, nhits = {}, {}, {}, 0;
local hit_size = 0;

local tab_labels = nil;
local head_labels = {}; -- bag -> text
local count_num, foot_gil, foot_used = nil, nil, nil;
local gil_str, used_str = '', '';
local actions = menu.new();
local menu_item = nil; -- the item the open menu is for

-- tooltip
local tip_for, tip_title, tip_lines, tip_colors = nil, nil, {}, {};

--[[ layout ]]--

local function columns(ctx)
    return math.max(MIN_COLS, math.min(MAX_COLS, ctx.settings.columns or 10));
end

local function rows(ctx)
    return math.max(MIN_ROWS, math.min(MAX_ROWS, ctx.settings.rows or 8));
end

local function commas(n)
    local s = tostring(math.floor(n)):reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (s:gsub('^,', ''));
end

local function place(list, cols, y)
    for i, e in ipairs(list) do
        ncells = ncells + 1;
        cell_item[ncells] = e;
        cell_x[ncells] = ((i - 1) % cols) * CELL;
        cell_y[ncells] = y + math.floor((i - 1) / cols) * CELL;
    end
    return y + math.ceil(#list / cols) * CELL;
end

local merged = {};

local function build(ctx)
    local cols, unified = columns(ctx), ctx.settings.unified ~= false;
    local key = ('%d:%d:%d:%s'):format(inventory.version, tab, cols, tostring(unified));
    if (key == built_key) then return; end
    built_key = key;

    for i = ncells, 1, -1 do cell_item[i] = nil; end
    ncells, used, capacity = 0, 0, 0;
    for i = #heads, 1, -1 do heads[i] = nil; end

    local bags = inventory.TABS[tab].bags;
    for _, id in ipairs(bags) do
        if (not inventory.UNCOUNTED[id]) then
            local b = inventory.bag(id);
            used, capacity = used + #b.items, capacity + b.max;
        end
    end

    if (unified) then
        for i = #merged, 1, -1 do merged[i] = nil; end
        for _, id in ipairs(bags) do
            for _, e in ipairs(inventory.bag(id).items) do merged[#merged + 1] = e; end
        end
        table.sort(merged, inventory.compare);
        content_h = place(merged, cols, 0);
    else
        local y = 0;
        for _, id in ipairs(bags) do
            local b = inventory.bag(id);
            if (b.max > 0) then
                if (#heads > 0) then y = y + SECTION_GAP; end
                heads[#heads + 1] = { bag = id, y = y, str = ('%s  %d / %d'):format(inventory.NAMES[id], #b.items, b.max) };
                y = place(b.items, cols, y + HEAD_H);
            end
        end
        content_h = y;
    end

    gil_str = commas(inventory.gil) .. ' gil';
    used_str = ('%d / %d'):format(used, capacity);
end

local function view_h(ctx)
    return rows(ctx) * CELL;
end

local function clamp_scroll(ctx)
    scroll = math.max(0, math.min(scroll, content_h - view_h(ctx)));
end

--[[ game state ]]--

function inv.update(ctx, dt)
    inventory.refresh();
    -- the menu is for an item that has since moved or gone
    if (menu_item ~= nil and actions:is_open()) then
        local b = inventory.bag(menu_item.bag);
        local still = false;
        for _, e in ipairs(b.items) do
            if (e == menu_item and e.id == menu_item.id) then still = true; break; end
        end
        if (not still) then actions:close(); end
    end
    if (not actions:is_open()) then menu_item = nil; end
end

function inv.packet_in(ctx, e)
    inventory.packet_in(e);
end

--[[ actions ]]--

local function queue(cmd)
    AshitaCore:GetChatManager():QueueCommand(1, cmd);
end

local function send(id, data)
    AshitaCore:GetPacketManager():AddOutgoingPacket(id, data);
end

-- outgoing packets, as xitools builds them.
local function move(e, to)
    -- 0x52: let the server pick the slot in another bag
    send(0x029, struct.pack('IIBBBB', 0, e.count, e.bag, to, e.index, 0x52):totable());
end

local function drop(e)
    send(0x028, struct.pack('IIBB', 0, e.count, e.bag, e.index):totable());
end

local TARGETS_OTHERS = 0xFC;

---menu entries for an item, or nil if there's nothing to do with it.
local function item_menu(e)
    local info, items = e.info, {};
    local in_inv, in_ward = e.bag == INVENTORY, WARDROBE[e.bag] == true;

    if (info.usable and (in_inv or in_ward)) then
        local target = band(info.targets, TARGETS_OTHERS) ~= 0 and '<t>' or '<me>';
        items[#items + 1] = { label = 'Use', action = function () queue(('/item "%s" %s'):format(info.name, target)); end };
    end
    if (in_inv and not e.locked) then
        items[#items + 1] = { label = 'Trade', action = function () queue(('/item "%s" <t>'):format(info.name)); end };
    end
    if (info.gear and (in_inv or in_ward)) then
        -- worn: its own slot becomes Unequip; any others (the other ear or
        -- ring) still swap it across
        -- TODO: test swapping across on retail
        local worn = inventory.worn_slot(e);
        for b = 0, 15 do
            local slot = inventory.SLOTS[band(info.slots, bit.lshift(1, b))];
            if (slot ~= nil and b == worn) then
                items[#items + 1] = { label = 'Unequip ' .. slot, action = function () queue('/equip ' .. slot); end };
            elseif (slot ~= nil) then
                items[#items + 1] = { label = 'Equip ' .. slot, action = function ()
                    queue(('/equip %s "%s"'):format(slot, info.name));
                end };
            end
        end
    end

    -- house bags only open in the mog house, and temporary items can't move
    local movable = not e.locked and e.bag ~= TEMPORARY and (in_inv or in_ward or e.bag == 5 or e.bag == 6 or e.bag == 7);
    if (movable) then
        local dest = {};
        for _, to in ipairs(MOVE_TO) do
            if (to ~= e.bag and (info.gear or not WARDROBE[to]) and inventory.has_access(to)) then
                dest[#dest + 1] = { label = 'to ' .. inventory.NAMES[to], action = function () move(e, to); end };
            end
        end
        if (#dest > 0) then
            items[#items + 1] = { sep = true };
            items[#items + 1] = { label = 'Move', items = dest };
        end
    end
    if (in_inv and not e.locked) then
        local what = e.count > 1 and ('%d %s'):format(e.count, info.log_many) or info.log_one;
        items[#items + 1] = { label = 'Drop', items = {
            { label = 'Drop ' .. what, action = function () drop(e); end },
        } };
    end

    if (#items == 0) then return nil; end
    if (items[#items].sep) then items[#items] = nil; end
    return items;
end

--[[ tooltip ]]--

local TITLE = { size = 13 };
local LINE  = { size = 12, bold = false };

local function set_tip(e)
    if (tip_for == e and e ~= nil) then return; end
    tip_for = e;
    if (e == nil) then return; end
    local info = e.info;

    local strs, colors = {}, {};
    local function add(s, color) strs[#strs + 1], colors[#colors + 1] = s, color; end
    for line in (info.desc .. '\n'):gmatch('(.-)\n') do
        if (line ~= '') then add(line, 'text'); end
    end
    if (info.gear) then
        local lv = info.level > 0 and ('Lv.%d '):format(info.level) or '';
        if ((info.ilevel or 0) > 0) then lv = lv .. ('(iLv.%d) '):format(info.ilevel); end
        add(lv .. (info.slot_name or ''), 'text_dim');
        if (info.job_names ~= '') then add(info.job_names, 'text_dim'); end
    end
    if (info.stack > 1) then add(('%d / %d'):format(e.count, info.stack), 'text_dim'); end
    add(inventory.NAMES[e.bag] .. (e.equipped and ', equipped' or ''), 'text_dim');

    tip_title = tip_title or text.new(TITLE);
    tip_title:set(info.label);
    for i, s in ipairs(strs) do
        tip_lines[i] = tip_lines[i] or text.new(LINE);
        tip_lines[i]:set(s);
        tip_colors[i] = colors[i];
    end
    for i = #tip_lines, #strs + 1, -1 do tip_lines[i], tip_colors[i] = nil, nil; end
end

local function draw_tip(r, ctx)
    if (tip_for == nil) then return; end
    local s, c = ctx.scale, theme.color;
    local w, h = tip_title:size();
    local line_h = 0;
    for _, l in ipairs(tip_lines) do
        local lw, lh = l:size();
        w, line_h = math.max(w, lw), math.max(line_h, lh);
    end
    local pad = PAD * s;
    w, h = w + pad * 2, h + 4 * s + #tip_lines * line_h + pad * 2;

    local x, y = ctx.mouse_x + 18 * s, ctx.mouse_y + 18 * s;
    if (x + w > ctx.screen_w) then x = ctx.mouse_x - w - 8 * s; end
    y = math.max(0, math.min(y, ctx.screen_h - h));

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('popup_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));
    local _, th = tip_title:draw(x + pad, y + pad, c('text'));
    local ly = y + pad + th + 4 * s;
    for i, l in ipairs(tip_lines) do
        l:draw(x + pad, ly, c(tip_colors[i]));
        ly = ly + line_h;
    end
end

--[[ drawing ]]--

--[[
* the grid's loops are each in a function of their own, taking only what they
* need. leaving a compiled loop is a side exit, and its side trace has to take
* over every value still live in the function there; inv.draw has more than
* moonjit can shuffle on 32-bit x86, so the side trace fails, and is retried
* a couple of hundred times before that exit is left to the interpreter (see
* ui/render.lua). the loop that draws cells also avoids branches that go
* different ways from one cell to the next, for the same reason.
--]]

---the cells in view, as a range: cell_y only grows with i.
local function visible_cells(oy, s, cs, vy, vh)
    local first, last = 1, ncells;
    while (first <= last and oy + cell_y[first] * s + cs <= vy) do first = first + 1; end
    while (last >= first and oy + cell_y[last] * s >= vy + vh) do last = last - 1; end
    return first, last;
end

---the cell under the mouse, or 0.
local function find_hot(first, last, vx, oy, s, cs, mx, my)
    local hot = 0;
    for i = first, last do
        local cx, cy = vx + cell_x[i] * s, oy + cell_y[i] * s;
        if (mx >= cx and mx < cx + cs and my >= cy and my < cy + cs) then hot = i; end
    end
    return hot;
end

---the cell the open menu is for, or 0.
local function find_menu(first, last)
    local found = 0;
    for i = first, last do
        if (cell_item[i] == menu_item) then found = i; end
    end
    return found;
end

---cell backgrounds, recording each cell's position for the passes after it
---and for clicks.
local function draw_cells(r, first, last, vx, oy, s, cs, hot_i, menu_i, bg, hover)
    for i = first, last do
        local cx, cy = vx + cell_x[i] * s, oy + cell_y[i] * s;
        local n = i - first + 1;
        hit_item[n], hit_x[n], hit_y[n] = cell_item[i], cx, cy;
        -- 1 for the hovered and menu cells, else 0
        local d0, d1 = i - hot_i, i - menu_i;
        local hot = 1 - math.min(1, d0 * d0, d1 * d1);
        r.nineslice('cell', cx + 1 * s, cy + 1 * s, cs - 2 * s, cs - 2 * s, bg + hot * (hover - bg));
    end
end

local function draw_icons(r, inset, is)
    for n = 1, nhits do
        local e = hit_item[n];
        icons.item(r, e.id, hit_x[n] + inset, hit_y[n] + inset, is, e.locked and 0xC0FFFFFF or nil);
    end
end

---stack counts and equipped marks.
local function draw_marks(r, s, cs, inset, text_color, mark_color)
    local _, count_h = count_num:size();
    for n = 1, nhits do
        local e = hit_item[n];
        if (e.info.stack > 1) then
            count_num:set(tostring(e.count));
            count_num:draw(hit_x[n] + cs - inset, hit_y[n] + cs - inset - count_h + 3 * s, text_color, 'right');
        end
        if (e.equipped) then
            r.sprite('dot', hit_x[n] + inset + 3 * s, hit_y[n] + inset + 3 * s, 0xFF000000, 2.5);
            r.sprite('dot', hit_x[n] + inset + 3 * s, hit_y[n] + inset + 3 * s, mark_color, 1.6);
        end
    end
end

function inv.measure(ctx)
    local s = ctx.scale;
    local w = PAD * 2 + columns(ctx) * CELL;
    local h = PAD + TAB_H + GAP + view_h(ctx) + GAP + FOOT_H + PAD * 0.5;
    return w * s, h * s;
end

function inv.draw(r, ctx, x, y)
    local w, h = inv.measure(ctx);
    local s, c = ctx.scale, theme.color;
    build(ctx);
    clamp_scroll(ctx);

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));

    -- tabs: labels are drawn with the rest of the text; their spans are kept
    -- for clicks.
    if (tab_labels == nil) then
        tab_labels = {};
        for i, t in ipairs(inventory.TABS) do tab_labels[i] = text.new({ text = t.name }); end
    end
    local tx, ty = x + PAD * s, y + PAD * s;
    tab_y0, tab_y1 = ty, ty + TAB_H * s;
    for i, l in ipairs(tab_labels) do
        local lw = l:size();
        tab_x0[i], tab_x1[i] = tx, tx + lw;
        if (i == tab) then
            r.rect(tx, ty + (TAB_H - 2) * s, lw, 2 * s, c('accent'));
        end
        tx = tx + lw + TAB_GAP * s;
    end

    -- the grid, clipped to the view
    local vx, vy = x + PAD * s, y + (PAD + TAB_H + GAP) * s;
    local vw, vh = columns(ctx) * CELL * s, view_h(ctx) * s;
    local oy = vy - scroll * s;
    local cs, is = CELL * s, ICON * s;
    local inset = (CELL - ICON) * 0.5 * s;
    local mx, my = ctx.mouse_x, ctx.mouse_y;
    local over_view = mx >= vx and mx < vx + vw and my >= vy and my < vy + vh;
    local hovered = nil;

    local first, last = visible_cells(oy, s, cs, vy, vh);
    local hot_i = over_view and find_hot(first, last, vx, oy, s, cs, mx, my) or 0;
    local menu_i = find_menu(first, last);
    if (hot_i ~= 0 and hot_i ~= menu_i) then hovered = cell_item[hot_i]; end

    nhits, hit_size = math.max(0, last - first + 1), cs;
    r.push_clip(vx, vy, vw, vh);
    draw_cells(r, first, last, vx, oy, s, cs, hot_i, menu_i, c('cell_bg'), c('hover'));
    draw_icons(r, inset, is);
    count_num = count_num or text.number('count');
    draw_marks(r, s, cs, inset, c('text'), c('accent'));
    for _, hd in ipairs(heads) do
        local hy = oy + hd.y * s;
        if (hy + HEAD_H * s > vy and hy < vy + vh) then
            local l = head_labels[hd.bag];
            if (l == nil) then
                l = text.new({ size = 11, bold = false });
                head_labels[hd.bag] = l;
            end
            l:set(hd.str);
            l:draw(vx + 2 * s, hy + 1 * s, c('text_dim'));
        end
    end
    r.pop_clip();

    -- scrollbar
    if (content_h > view_h(ctx)) then
        local bx = x + w - (PAD * 0.5 + BAR_W * 0.5) * s;
        local th = math.max(16 * s, vh * view_h(ctx) / content_h);
        local ty_ = vy + (vh - th) * scroll / (content_h - view_h(ctx));
        r.rect(bx, vy, BAR_W * s, vh, c('bar_bg'));
        r.rect(bx, ty_, BAR_W * s, th, c('text_dim'));
    end

    -- footer: gil, then space used
    local fy = vy + vh + GAP * s;
    foot_gil = foot_gil or text.number('inv');
    foot_used = foot_used or text.number('inv');
    foot_gil:set(gil_str);
    foot_used:set(used_str);
    foot_gil:draw(x + PAD * s, fy, c('text'));
    foot_used:draw(x + w - PAD * s, fy, c(used >= capacity and capacity > 0 and 'hp_crit' or 'text_dim'), 'right');

    for i, l in ipairs(tab_labels) do
        l:draw(tab_x0[i], ty, c(i == tab and 'text' or 'text_dim'));
    end

    if (actions:is_open()) then
        set_tip(nil);
    else
        set_tip(hovered);
        draw_tip(r, ctx);
    end
    actions:draw(r, ctx);
    ctx.modal = actions:is_open() or nil;
    return w, h;
end

--[[ mouse ]]--

local function item_at(sx, sy)
    for n = 1, nhits do
        if (sx >= hit_x[n] and sx < hit_x[n] + hit_size and sy >= hit_y[n] and sy < hit_y[n] + hit_size) then
            return hit_item[n];
        end
    end
    return nil;
end

function inv.mouse(ctx, ev, mx, my, e)
    local sx, sy = ctx.x + mx, ctx.y + my;
    local res = actions:mouse(ev, sx, sy, ctx.scale);
    if (res == 'used') then return true; end
    if (mx < 0 or my < 0 or mx >= ctx.w or my >= ctx.h) then
        return res == 'closed'; -- a click off the menu and off the panel
    end

    if (ev == 'wheel') then
        scroll = scroll + (e.delta < 0 and CELL or -CELL);
        clamp_scroll(ctx);
    elseif (ev == 'ldown') then
        if (sy >= tab_y0 and sy < tab_y1) then
            for i = 1, #inventory.TABS do
                if (sx >= tab_x0[i] - TAB_GAP * 0.5 * ctx.scale and sx < tab_x1[i] + TAB_GAP * 0.5 * ctx.scale) then
                    if (tab ~= i) then tab, scroll = i, 0; end
                    break;
                end
            end
        end
    elseif (ev == 'rdown') then
        local item = item_at(sx, sy);
        local entries = item and item_menu(item);
        if (entries ~= nil) then
            actions:open(entries, sx + 2, sy + 2);
            menu_item = item;
        end
    end
    return true; -- the panel takes every click aimed at it
end

--[[ commands ]]--

---/linhud inv columns <n> | rows <n> | unified [on|off]
function inv.command(ctx, args)
    local s = ctx.settings;
    if (args[1] == 'columns' or args[1] == 'rows') then
        local lo, hi = MIN_COLS, MAX_COLS;
        if (args[1] == 'rows') then lo, hi = MIN_ROWS, MAX_ROWS; end
        local n = tonumber(args[2]);
        if (args[2] ~= nil) then
            if (n == nil or n < lo or n > hi) then
                return true, ('%s must be %d to %d'):format(args[1], lo, hi);
            end
            s[args[1]] = math.floor(n);
        end
        return true, ('inv %s: %d'):format(args[1], s[args[1]]);
    end
    if (args[1] == 'unified') then
        if (args[2] == 'on' or args[2] == 'off') then
            s.unified = args[2] == 'on';
        elseif (args[2] == nil) then
            s.unified = s.unified == false;
        else
            return true, 'usage: /linhud inv unified [on|off]';
        end
        return true, ('inv unified: %s'):format(s.unified and 'on' or 'off');
    end
    return false;
end

--[[ lifecycle ]]--

-- packets were going unread while this was off
inventory.mark(nil);

function inv.destroy(ctx)
    actions:close();
end

return inv;
