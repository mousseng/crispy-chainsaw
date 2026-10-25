--[[
* toasts: requests from other players, stacked as cards with buttons to
* answer them.
*
*   party invite    (0x0DC, kind 0)  Join / Decline, sent as /join, /decline
*   alliance invite (0x0DC, kind 5)  the same, between party leaders
*   trade request   (0x021)          Accept / Decline, sent as 0x033
*
* a card goes once the request is answered, here or through the game's own
* prompts (we watch the outgoing 0x074 / 0x033), once the trade starts or is
* called off (0x022 from the requester), or on zoning. invites don't expire
* on the server, so their cards stay until answered; trade cards go after
* TRADE_TTL (the server lets the requester ask again then). right-clicking a
* card dismisses it without answering.
*
* toast.push(def) adds any other kind of card: { key, title, body, color,
* ttl, actions = { { label, fn }, ... } }. a push with the key of a live card
* replaces it.
*
* `/cc toast demo` shows one of each; their buttons only close the card.
--]]

local hud   = require('ui.hud');
local text  = require('ui.text');
local theme = require('ui.theme');

local toast = {}; -- settings defaults: components/list.lua

local TRADE_TTL = 60;   -- seconds a trade card stays unanswered
local FADE = 0.2;       -- seconds a card takes to open or close
local PARTY, ALLIANCE = 0, 5; -- 0x0DC kinds

-- layout, logical px. a card: a coloured strip, title over body on the left,
-- buttons on the right, and a time-left bar along the bottom if it expires.
local W, H, PAD, GAP, STRIP = 280, 48, 8, 6, 3;
local BTN_W, BTN_H, BAR_H = 58, 18, 2;

local cards = {};       -- { key, title, body, color, ttl, left, actions, alpha, closing }, oldest first
local unlocked_hint = nil;

-- buttons drawn last frame, for the mouse (screen px).
local btn_card, btn_act, btn_x, btn_y, btn_w, btn_h, nbtns = {}, {}, {}, {}, {}, {}, 0;
-- cards drawn last frame (screen px), for right-click dismissal.
local card_ref, card_y, card_h, ncards = {}, {}, {}, 0;

--[[ cards ]]--

local function find(key)
    for i = 1, #cards do
        if (cards[i].key == key and not cards[i].closing) then return cards[i]; end
    end
    return nil;
end

---starts a card closing; it fades out and the stack closes up behind it.
local function close(c)
    if (c ~= nil) then c.closing = true; end
end

local function close_key(key)
    close(find(key));
end

---@param def table { key, title, body, color, ttl, actions = { { label, fn } } }
function toast.push(def)
    local c = find(def.key);
    local alpha = 0;
    if (c ~= nil) then
        alpha = c.alpha; -- replacing a live card: no reopen animation
        for i = 1, #cards do
            if (cards[i] == c) then table.remove(cards, i); break; end
        end
    end
    c = {
        key = def.key, color = def.color or 'accent', ttl = def.ttl, left = def.ttl,
        actions = def.actions or {}, alpha = alpha, closing = false,
        title = text.new({ text = def.title or '', size = 11, bold = false }),
        body = text.new({ text = def.body or '', size = 13 }),
    };
    cards[#cards + 1] = c;
    return c;
end

--[[ requests ]]--

local function party_card(kind, name)
    local alliance = kind == ALLIANCE;
    toast.push({
        key = 'invite', -- the server keeps one pending invite; a new one replaces it
        title = alliance and 'Alliance invite' or 'Party invite',
        body = name,
        color = alliance and 'toast_alliance' or 'toast_party',
        actions = {
            { label = 'Join',    fn = function () AshitaCore:GetChatManager():QueueCommand(1, '/join'); end },
            { label = 'Decline', fn = function () AshitaCore:GetChatManager():QueueCommand(1, '/decline'); end },
        },
    });
end

---0x033: Kind 0 starts the trade, 1 refuses it.
local function trade_res(kind)
    AshitaCore:GetPacketManager():AddOutgoingPacket(0x033, { 0, 0, 0, 0, kind, 0, 0, 0, 0, 0, 0, 0 });
end

local function trade_card(name)
    toast.push({
        key = 'trade', -- the server keeps one partner per player
        title = 'Trade request',
        body = name,
        color = 'toast_trade',
        ttl = TRADE_TTL,
        actions = {
            { label = 'Accept',  fn = function () trade_res(0); end },
            { label = 'Decline', fn = function () trade_res(1); end },
        },
    });
end

local trade_from = 0; -- the trade card's requester (server id)

function toast.packet_in(ctx, e)
    local id = e.id;
    if (id == 0x0DC) then
        local kind = struct.unpack('B', e.data, 0x0B + 1);
        local name = e.data:sub(0x0C + 1, 0x0C + 16):match('^[^%z]*');
        party_card(kind, name ~= '' and name or 'Someone');
    elseif (id == 0x021) then
        trade_from = struct.unpack('I', e.data, 0x04 + 1);
        local index = struct.unpack('H', e.data, 0x08 + 1);
        local name = AshitaCore:GetMemoryManager():GetEntity():GetName(index);
        trade_card((name ~= nil and name ~= '') and name or 'Someone');
    elseif (id == 0x022) then
        -- the trade window opening, or the requester calling it off
        if (struct.unpack('I', e.data, 0x04 + 1) == trade_from) then close_key('trade'); end
    elseif (id == 0x00A) then
        -- zoning drops pending invites and trades on the server
        for i = 1, #cards do close(cards[i]); end
    end
end

---answered through the game's own prompts (or our buttons, if ashita shows
---us injected packets too).
function toast.packet_out(ctx, e)
    if (e.id == 0x074) then
        close_key('invite');
    elseif (e.id == 0x033) then
        close_key('trade');
    end
end

--[[ update ]]--

function toast.update(ctx, dt)
    local step = dt / FADE;
    local i = 1;
    while (i <= #cards) do
        local c = cards[i];
        if (c.left ~= nil and not c.closing) then
            c.left = c.left - dt;
            if (c.left <= 0) then c.closing = true; end
        end
        if (c.closing) then
            c.alpha = c.alpha - step;
        elseif (c.alpha < 1) then
            c.alpha = math.min(1, c.alpha + step);
        end
        if (c.alpha <= 0) then
            table.remove(cards, i);
        else
            i = i + 1;
        end
    end
end

--[[ drawing ]]--

---a card's share of the stack: it opens and closes like a drawer.
local function slot_h(c)
    return (H + GAP) * c.alpha;
end

function toast.measure(ctx)
    local h = 0;
    for i = 1, #cards do h = h + slot_h(cards[i]); end
    if (h == 0 and hud.is_unlocked()) then h = H + GAP; end -- something to place
    if (h == 0) then return 0, 0; end
    return W * ctx.scale, (h - GAP) * ctx.scale;
end

local function button(r, ctx, x, y, w, h, l, c, act)
    local col = theme.color;
    local mx, my = ctx.mouse_x, ctx.mouse_y;
    local hot = not c.closing and mx >= x and mx < x + w and my >= y and my < y + h;
    r.nineslice('cell', x, y, w, h, col(hot and 'hover' or 'cell_bg'));
    local _, lh = l:size();
    l:draw(x + w * 0.5, y + (h - lh) * 0.5, col('text'), 'center');
    if (not c.closing) then
        nbtns = nbtns + 1;
        btn_card[nbtns], btn_act[nbtns] = c, act;
        btn_x[nbtns], btn_y[nbtns], btn_w[nbtns], btn_h[nbtns] = x, y, w, h;
    end
end

local function draw_card(r, ctx, c, x, y)
    local s, col = ctx.scale, theme.color;
    local w, h = W * s, H * s;
    local accent = col(c.color);

    r.set_opacity(c.alpha);
    r.nineslice('panel_shadow', x, y, w, h, col('shadow'));
    r.nineslice('panel', x, y, w, h, col('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, col('panel_border'));
    r.rect(x + 1 * s, y + 4 * s, STRIP * s, h - 8 * s, accent);

    -- title over body, left; buttons, right (first action rightmost-but-one)
    local n = #c.actions;
    local bx = x + w - PAD * s - n * BTN_W * s - (n - 1) * 4 * s;
    local lx = x + (PAD + STRIP + 4) * s;
    local _, th = c.title:size();
    local _, bh = c.body:size();
    local ty = y + (h - th - bh) * 0.5;
    r.push_clip(lx, y, bx - lx - GAP * s, h);
    c.title:draw(lx, ty, accent);
    c.body:draw(lx, ty + th, col('text'));
    r.pop_clip();

    local by = y + (h - BTN_H * s) * 0.5;
    for i = 1, n do
        local a = c.actions[i];
        a.text = a.text or text.new({ text = a.label, size = 11 });
        button(r, ctx, bx, by, BTN_W * s, BTN_H * s, a.text, c, a);
        bx = bx + (BTN_W + 4) * s;
    end

    -- time left
    if (c.ttl ~= nil) then
        local frac = math.max(0, c.left / c.ttl);
        r.rect(x + 1 * s, y + h - (BAR_H + 1) * s, (w - 2 * s) * frac, BAR_H * s, accent);
    end
    r.set_opacity(1);
end

function toast.draw(r, ctx, x, y)
    nbtns, ncards = 0, 0;
    local w, h = toast.measure(ctx);
    if (w == 0) then return 0, 0; end
    local s = ctx.scale;

    if (#cards == 0) then
        -- unlocked with nothing to show: an empty card to drag around
        local col = theme.color;
        r.nineslice('panel', x, y, w, h, col('panel_bg'));
        r.nineslice('panel_border', x, y, w, h, col('panel_border'));
        unlocked_hint = unlocked_hint or text.new({ text = 'Notifications', size = 11, bold = false });
        local _, lh = unlocked_hint:size();
        unlocked_hint:draw(x + w * 0.5, y + (h - lh) * 0.5, col('text_dim'), 'center');
        return w, h;
    end

    local cy = y;
    for i = 1, #cards do
        local c = cards[i];
        local sh = slot_h(c) * s;
        local vis = math.min(sh, H * s);
        if (vis > 0) then
            -- clipped only while opening or closing, so the shadow shows otherwise
            local part = vis < H * s;
            if (part) then r.push_clip(x, cy, w, vis); end
            draw_card(r, ctx, c, x, cy);
            if (part) then r.pop_clip(); end
            ncards = ncards + 1;
            card_ref[ncards], card_y[ncards], card_h[ncards] = c, cy, vis;
        end
        cy = cy + sh;
    end
    return w, h;
end

--[[ mouse ]]--

function toast.mouse(ctx, ev, mx, my, e)
    local sx, sy = ctx.x + mx, ctx.y + my;
    if (ev == 'ldown') then
        for i = 1, nbtns do
            if (sx >= btn_x[i] and sx < btn_x[i] + btn_w[i] and sy >= btn_y[i] and sy < btn_y[i] + btn_h[i]) then
                local c = btn_card[i];
                if (not c.closing) then
                    if (btn_act[i].fn ~= nil) then btn_act[i].fn(); end
                    close(c);
                end
                return true;
            end
        end
    elseif (ev == 'rdown') then
        for i = 1, ncards do
            if (sy >= card_y[i] and sy < card_y[i] + card_h[i]) then
                close(card_ref[i]);
                return true;
            end
        end
    end
    -- only the cards take clicks; the gaps between them don't
    for i = 1, ncards do
        if (sy >= card_y[i] and sy < card_y[i] + card_h[i]) then return ev ~= 'wheel'; end
    end
    return false;
end

--[[ commands ]]--

---/cc toast demo - one card of each kind; the buttons only close them.
---/cc toast clear - dismisses every card.
function toast.command(ctx, args)
    if (args[1] == 'demo') then
        toast.push({ key = 'demo_party', title = 'Party invite', body = 'Somebody', color = 'toast_party',
            actions = { { label = 'Join' }, { label = 'Decline' } } });
        toast.push({ key = 'demo_alliance', title = 'Alliance invite', body = 'Someoneelse', color = 'toast_alliance',
            actions = { { label = 'Join' }, { label = 'Decline' } } });
        toast.push({ key = 'demo_trade', title = 'Trade request', body = 'Anybody', color = 'toast_trade', ttl = TRADE_TTL,
            actions = { { label = 'Accept' }, { label = 'Decline' } } });
        return true, 'toast demo: on';
    elseif (args[1] == 'clear') then
        for i = 1, #cards do close(cards[i]); end
        return true;
    end
    return false;
end

return toast;
