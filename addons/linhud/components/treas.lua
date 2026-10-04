--[[
* treasure pool: what's in the pool, who's winning each item, and buttons to
* lot or pass, one item at a time or all at once (as xitools' treas does).
*
* only shown while the pool has something in it, or while the hud is
* unlocked, so it can be placed. rows go in pool slot order. an item the
* player is winning is gold, one they've passed is dimmed.
*
* time left comes from game/treasure.lua, which watches drops even while this
* is off. an item already in the pool when it was first seen (joining a party,
* loading the addon) shows ??? until a couple of new drops have shown how the
* server's clock maps to ours.
*
* `/linhud treas demo` fills the pool with fake items to try it out solo;
* lotting and passing those never reaches the server. `/linhud treas clock`
* says what's known about the server's clock.
--]]

local hud       = require('ui.hud');
local inventory = require('game.inventory');
local icons     = require('ui.icons');
local text      = require('ui.text');
local theme     = require('ui.theme');
local treasure  = require('game.treasure');

local treas = {}; -- settings defaults: components/list.lua

local POLL = 0.1;       -- seconds between pool reads
local SLOTS = 10;       -- the pool's size
local LIFETIME = 300;   -- seconds an item stays in the pool
local PENDING = 2;      -- seconds a lot or pass waits for the server before it can be sent again
local PASSED = 0xFFFF;  -- the player's lot once they've passed
local LOT_OUT, PASS_OUT = 0x041, 0x042;

-- layout, logical px. a row: icon, name, time left, winning lot and winner,
-- then the player's lot (or a Lot button) and a Pass button.
local W, PAD, HEAD_H, ROW_H = 448, 8, 22, 26;
local ICON, NAME_W, TIME_W, WLOT_W, WIN_W, BTN_W, BTN_H, GAP = 20, 150, 36, 30, 92, 40, 18, 6;
local HEAD_BTN_W = 56;

-- reused records, one per pool slot; `rows` lists the filled ones in order.
local pool = {};
for i = 0, SLOTS - 1 do
    pool[i] = {
        slot = i, id = 0, drop = -1, label = '', lot = 0, win_lot = 0, win_sid = 0, win_name = '',
        expires = nil, secs = -1, time_str = '', lot_str = '', win_lot_str = '', pending = 0,
        name_text = nil, win_text = nil, time_num = nil, lot_num = nil, win_num = nil,
    };
end
local rows, nrows = {}, 0;
local since_poll = POLL;
local my_sid = 0;
local demo = false;

-- buttons drawn last frame, for the mouse (screen px). kind: 'lot' | 'pass'
-- for one slot, 'lot_all' | 'pass_all' for every slot.
local btn_kind, btn_slot, btn_x, btn_y, btn_w, btn_h, nbtns = {}, {}, {}, {}, {}, {}, 0;

local title, lbl_lot, lbl_pass, lbl_lot_all, lbl_pass_all, lbl_passed, lbl_unknown = nil, nil, nil, nil, nil, nil, nil;

--[[ game state ]]--

local function now()
    return os.time();
end

local function set_lot(e, lot)
    if (lot ~= e.lot) then
        e.lot = lot;
        e.lot_str = (lot > 0 and lot < PASSED) and tostring(lot) or '';
    end
end

local function set_winner(e, lot, sid, name)
    if (lot ~= e.win_lot) then
        e.win_lot = lot;
        e.win_lot_str = lot > 0 and tostring(lot) or '';
    end
    e.win_sid, e.win_name = sid, lot > 0 and name or '';
end

---e.secs is -1 while the expiry isn't known.
local function set_time(e, t)
    local secs = e.expires and math.max(0, e.expires - t) or -1;
    if (secs ~= e.secs) then
        e.secs = secs;
        e.time_str = secs >= 0 and ('%d:%02d'):format(math.floor(secs / 60), secs % 60) or '';
    end
end

local function list_rows()
    nrows = 0;
    for i = 0, SLOTS - 1 do
        if (pool[i].id ~= 0) then
            nrows = nrows + 1;
            rows[nrows] = pool[i];
        end
    end
    for i = #rows, nrows + 1, -1 do rows[i] = nil; end
end

local function poll()
    local mm = AshitaCore:GetMemoryManager();
    local inv, party = mm:GetInventory(), mm:GetParty();
    my_sid = party:GetMemberServerId(0);
    local t = now();
    for i = 0, SLOTS - 1 do
        local e, item = pool[i], inv:GetTreasurePoolItem(i);
        local id = item ~= nil and item.ItemId or 0;
        if (id == 0) then
            e.id = 0;
        else
            if (id ~= e.id or item.DropTime ~= e.drop) then
                local info = inventory.info(id);
                e.id, e.drop, e.pending = id, item.DropTime, 0;
                e.label = info and info.label or ('item #%d'):format(id);
            end
            e.expires = treasure.expires(i, id, item.DropTime); -- may become known later
            set_lot(e, item.Lot);
            set_winner(e, item.WinningLot, item.WinningEntityServerId, item.WinningEntityName);
            set_time(e, t);
        end
    end
    list_rows();
end

--[[ demo ]]--

local DEMO = {
    { id = 4096,  win = 0,   name = '' },
    { id = 4112,  win = 712, name = 'Somebody' },
    { id = 640,   win = 0,   name = '' },
    { id = 17307, win = 0,   name = '' },
};
local SOMEBODY = -1; -- the fake winner's server id: never the player's

local function demo_fill()
    local t = now();
    my_sid = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
    for i = 0, SLOTS - 1 do pool[i].id = 0; end
    for i, d in ipairs(DEMO) do
        local e, info = pool[i - 1], inventory.info(d.id);
        e.id, e.drop, e.expires, e.pending = d.id, -1, t + LIFETIME - i * 50, 0;
        e.label = info and info.label or ('item #%d'):format(d.id);
        set_lot(e, 0);
        set_winner(e, d.win, SOMEBODY, d.name);
    end
    list_rows();
end

local function demo_tick()
    local t = now();
    for n = 1, nrows do set_time(rows[n], t); end
end

--[[ actions ]]--

local function send(id, slot)
    AshitaCore:GetPacketManager():AddOutgoingPacket(id, { 0x00, 0x00, 0x00, 0x00, slot });
end

local function can_lot(e)
    return e.id ~= 0 and e.lot == 0 and e.pending <= now();
end

local function can_pass(e)
    return e.id ~= 0 and e.lot ~= PASSED and e.pending <= now();
end

local function lot(e)
    if (not can_lot(e)) then return; end
    if (demo) then
        set_lot(e, math.random(1, 999));
        if (e.lot > e.win_lot) then set_winner(e, e.lot, my_sid, 'You'); end
        return;
    end
    e.pending = now() + PENDING;
    send(LOT_OUT, e.slot);
end

local function pass(e)
    if (not can_pass(e)) then return; end
    if (demo) then
        if (e.win_sid == my_sid and e.win_lot > 0) then set_winner(e, 0, 0, ''); end
        set_lot(e, PASSED);
        return;
    end
    e.pending = now() + PENDING;
    send(PASS_OUT, e.slot);
end

function treas.update(ctx, dt)
    since_poll = since_poll + dt;
    if (since_poll < POLL) then return; end
    since_poll = 0;
    if (demo) then demo_tick(); else poll(); end
end

--[[ drawing ]]--

local function shown()
    return nrows > 0 or hud.is_unlocked();
end

function treas.measure(ctx)
    if (not shown()) then return 0, 0; end
    return W * ctx.scale, (PAD * 2 + HEAD_H + nrows * ROW_H) * ctx.scale;
end

---a button: a cell, highlighted under the mouse, with its label centred.
---records it for the mouse.
local function button(r, ctx, x, y, w, h, label, kind, slot, enabled)
    local c = theme.color;
    local mx, my = ctx.mouse_x, ctx.mouse_y;
    local hot = enabled and mx >= x and mx < x + w and my >= y and my < y + h;
    r.nineslice('cell', x, y, w, h, c(hot and 'hover' or 'cell_bg'));
    local _, lh = label:size();
    label:draw(x + w * 0.5, y + (h - lh) * 0.5, c(enabled and 'text' or 'text_dim'), 'center');
    if (enabled) then
        nbtns = nbtns + 1;
        btn_kind[nbtns], btn_slot[nbtns] = kind, slot;
        btn_x[nbtns], btn_y[nbtns], btn_w[nbtns], btn_h[nbtns] = x, y, w, h;
    end
end

local function draw_row(r, ctx, e, x, y, s)
    local c = theme.color;
    local mine = e.win_lot > 0 and e.win_sid == my_sid;
    local passed = e.lot == PASSED;
    local col = c(mine and 'loot_win' or (passed and 'text_dim' or 'text'));
    local cy = y + ROW_H * 0.5 * s;

    icons.item(r, e.id, x, cy - ICON * 0.5 * s, ICON * s, passed and 0x80FFFFFF or nil);

    -- name, clipped to its column
    local nx = x + (ICON + GAP) * s;
    e.name_text = e.name_text or text.new({ size = 12 });
    e.name_text:set(e.label);
    local _, nh = e.name_text:size();
    r.push_clip(nx, y, NAME_W * s, ROW_H * s);
    e.name_text:draw(nx, cy - nh * 0.5, col);
    r.pop_clip();

    -- time left, then the winning lot and who has it
    local tx = nx + (NAME_W + TIME_W) * s;
    e.time_num = e.time_num or text.number('number');
    e.time_num:set(e.time_str);
    local _, th = e.time_num:size();
    if (e.secs >= 0) then
        e.time_num:draw(tx, cy - th * 0.5, c(e.secs <= 60 and 'hp_crit' or 'text_dim'), 'right');
    else
        local _, uh = lbl_unknown:size();
        lbl_unknown:draw(tx, cy - uh * 0.5, c('text_dim'), 'right');
    end

    local wx = tx + WLOT_W * s;
    if (e.win_lot > 0) then
        e.win_num = e.win_num or text.number('number');
        e.win_num:set(e.win_lot_str);
        e.win_num:draw(wx, cy - th * 0.5, col, 'right');
        e.win_text = e.win_text or text.new({ size = 12, bold = false });
        e.win_text:set(e.win_name);
        local _, wh = e.win_text:size();
        r.push_clip(wx + GAP * s, y, WIN_W * s, ROW_H * s);
        e.win_text:draw(wx + GAP * s, cy - wh * 0.5, mine and col or c('text'));
        r.pop_clip();
    end

    -- the player's lot, or a button to lot; then pass
    local bx = wx + (GAP + WIN_W + GAP) * s;
    local by, bw, bh = cy - BTN_H * 0.5 * s, BTN_W * s, BTN_H * s;
    if (e.lot == 0) then
        button(r, ctx, bx, by, bw, bh, lbl_lot, 'lot', e.slot, can_lot(e));
    elseif (passed) then
        local _, ph = lbl_passed:size();
        lbl_passed:draw(bx + bw * 0.5, cy - ph * 0.5, c('text_dim'), 'center');
    else
        e.lot_num = e.lot_num or text.number('number');
        e.lot_num:set(e.lot_str);
        e.lot_num:draw(bx + bw * 0.5, cy - th * 0.5, col, 'center');
    end
    if (not passed) then
        button(r, ctx, bx + bw + 4 * s, by, bw, bh, lbl_pass, 'pass', e.slot, can_pass(e));
    end
end

function treas.draw(r, ctx, x, y)
    nbtns = 0;
    local w, h = treas.measure(ctx);
    if (w == 0) then return 0, 0; end
    local s, c = ctx.scale, theme.color;

    if (title == nil) then
        title = text.new({ text = 'Treasure', size = 13 });
        lbl_lot = text.new({ text = 'Lot', size = 11 });
        lbl_pass = text.new({ text = 'Pass', size = 11 });
        lbl_lot_all = text.new({ text = 'Lot all', size = 11 });
        lbl_pass_all = text.new({ text = 'Pass all', size = 11 });
        lbl_passed = text.new({ text = 'passed', size = 11, bold = false });
        lbl_unknown = text.new({ text = '???', size = 11, bold = false });
    end

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));

    -- header: title, then lot all / pass all on the right
    local lx, rx, hy = x + PAD * s, x + w - PAD * s, y + PAD * s;
    local _, tth = title:size();
    title:draw(lx, hy + (HEAD_H * s - tth) * 0.5, c('text'));
    local any_lot, any_pass = false, false;
    for n = 1, nrows do
        any_lot = any_lot or can_lot(rows[n]);
        any_pass = any_pass or can_pass(rows[n]);
    end
    local bw, bh = HEAD_BTN_W * s, BTN_H * s;
    local by = hy + (HEAD_H - BTN_H) * 0.5 * s;
    button(r, ctx, rx - bw, by, bw, bh, lbl_pass_all, 'pass_all', -1, any_pass);
    button(r, ctx, rx - bw * 2 - 4 * s, by, bw, bh, lbl_lot_all, 'lot_all', -1, any_lot);

    local ry = hy + HEAD_H * s;
    for n = 1, nrows do
        draw_row(r, ctx, rows[n], lx, ry, s);
        ry = ry + ROW_H * s;
    end
    return w, h;
end

--[[ mouse ]]--

function treas.mouse(ctx, ev, mx, my, e)
    if (ev ~= 'ldown') then return ev ~= 'wheel'; end
    local sx, sy = ctx.x + mx, ctx.y + my;
    for i = 1, nbtns do
        if (sx >= btn_x[i] and sx < btn_x[i] + btn_w[i] and sy >= btn_y[i] and sy < btn_y[i] + btn_h[i]) then
            local kind = btn_kind[i];
            if (kind == 'lot') then lot(pool[btn_slot[i]]);
            elseif (kind == 'pass') then pass(pool[btn_slot[i]]);
            else
                for n = 1, nrows do
                    if (kind == 'lot_all') then lot(rows[n]); else pass(rows[n]); end
                end
            end
            break;
        end
    end
    return true; -- the panel takes every click aimed at it
end

--[[ commands ]]--

---/linhud treas demo - toggles a fake pool to try the panel out with.
---/linhud treas clock - what's known about the server's pool clock.
function treas.command(ctx, args)
    if (args[1] == 'demo') then
        demo = not demo;
        if (demo) then demo_fill(); else poll(); end
        return true, ('treas demo: %s'):format(demo and 'on' or 'off');
    elseif (args[1] == 'clock') then
        return true, ('treas clock: %s'):format(treasure.describe());
    end
    return false;
end

return treas;
