--[[
* target: the current target's name, hp and distance, plus the subtarget while
* one is being picked (<st>, <stpc>, ...).
*
* names are coloured by what the target is (party member, player, npc,
* monster) and, for monsters, who holds claim. locking on rings the panel in a
* glow. entity state is read every frame (it's cheap and targets change
* instantly); the party's ids, used for colouring, at 10hz.
*
* while the party has a skillchain going on the main target
* (game/skillchain.lua), its resonance shows between the target and the
* subtarget: each name in its elements' colours, and the window's countdown
* (waiting, then open) with a bar. it goes once the window closes.
* `/linhud target test` puts a made-up chain on the current target.
--]]

local bit     = require('bit');
local sc      = require('game.skillchain');
local targets = require('game.targets');
local text    = require('ui.text');
local theme   = require('ui.theme');
local widgets = require('ui.widgets');

local band = bit.band;

local POLL = 0.1;                      -- seconds between party reads
local SPAWN_PC, SPAWN_MOB = 0x01, 0x10; -- entity spawn flags

local target = {}; -- settings defaults: components/list.lua

local function new_info()
    return {
        index = 0, sid = 0, name = '', kind = 'name_npc', hpp = -1, dist = -1,
        hpp_str = '', dist_str = '',
        name_text = nil, hp_num = nil, dist_num = nil,
    };
end
local main, sub = new_info(), new_info();
local locked = false;

-- the main target's skillchain record while its window is open, else nil
local chain = nil;
local clock = 0;
local chain_labels = {}; -- resonance name -> text
local chain_time, chain_wait, chain_go = nil, nil, nil;
local band_colors = {};

-- the main target's hp bar trail, and the target it belongs to: a new target
-- (or the same one again after a break) starts at its hp, not from the last one's.
local trail, trail_idx = widgets.trail_new(), 0;

-- alliance members' server ids and entity indices, for name colours.
local party_sid, party_idx = {}, {};
local since_poll = POLL;

--[[ game state ]]--

local function poll_party()
    for k in pairs(party_sid) do party_sid[k] = nil; end
    for k in pairs(party_idx) do party_idx[k] = nil; end
    local p = AshitaCore:GetMemoryManager():GetParty();
    if (p == nil) then return; end
    for i = 0, 17 do
        if (p:GetMemberIsActive(i) ~= 0) then
            local sid, idx = p:GetMemberServerId(i), p:GetMemberTargetIndex(i);
            if (sid ~= 0) then party_sid[sid] = true; end
            if (idx ~= 0) then party_idx[idx] = true; end
        end
    end
end

---palette key for the entity's name.
local function kind_of(ent, idx)
    if (party_idx[idx]) then return 'name_party'; end
    local flags = ent:GetSpawnFlags(idx);
    if (band(flags, SPAWN_PC) ~= 0) then return 'name_player'; end
    if (band(flags, SPAWN_MOB) ~= 0) then
        local claim = ent:GetClaimStatus(idx);
        if (claim == 0) then return 'name_mob'; end
        return party_sid[claim] and 'name_claimed' or 'name_claimed_other';
    end
    return 'name_npc';
end

local function read(info, idx)
    info.index = 0;
    if (idx == 0) then return; end
    local ent = AshitaCore:GetMemoryManager():GetEntity();
    local name = ent:GetName(idx);
    if (name == nil or name == '') then return; end -- despawned

    info.index = idx;
    info.sid = ent:GetServerId(idx);
    info.name = name;
    info.kind = kind_of(ent, idx);
    local hpp = ent:GetHPPercent(idx);
    if (hpp ~= info.hpp) then
        info.hpp, info.hpp_str = hpp, hpp .. '%';
    end
    local dist = math.floor(math.sqrt(ent:GetDistance(idx)) * 10 + 0.5); -- tenths of a yalm
    if (dist ~= info.dist) then
        info.dist, info.dist_str = dist, ('%.1f'):format(dist / 10);
    end
end

function target.update(ctx, dt)
    since_poll = since_poll + dt;
    if (since_poll >= POLL) then
        since_poll = 0;
        poll_party();
    end
    local m, s = targets.indices();
    read(main, m);
    read(sub, s ~= m and s or 0); -- picking the main target itself: one entry is enough
    if (main.index ~= trail_idx) then
        trail_idx = main.index;
        widgets.trail_reset(trail, main.hpp / 100);
    else
        widgets.trail_step(trail, main.hpp / 100, dt, true);
    end
    locked = main.index ~= 0 and targets.locked();

    clock = sc.now();
    sc.tick(clock);
    local m = main.index ~= 0 and sc.mobs[main.sid] or nil;
    chain = (m ~= nil and clock <= m.closes) and m or nil;
end

function target.packet_in(ctx, e)
    sc.packet_in(e);
end

--[[ drawing ]]--

-- layout in logical pixels. main: name, then the hp bar, then distance (left)
-- and hp% (right) under it. sub: one line of marker, name and a short bar.
local W, PAD = 240, 8;
local BAR_H, BAR_Y, NUM_Y, MAIN_H = 8, 17, 24, 38;
local SUB_H, SUB_GAP, SUB_BAR_W, SUB_BAR_H, MARK_W = 18, 6, 64, 5, 14;
-- the skillchain: resonance names and the countdown, then the window's bar
local CHAIN_H, CHAIN_BAR_Y, CHAIN_BAR_H, CHAIN_GAP, CHAIN_TIME_W = 22, 17, 4, 8, 70;

function target.measure(ctx)
    local has_main, has_sub = main.index ~= 0, sub.index ~= 0;
    if (not has_main and not has_sub) then
        return 0, 0;
    end
    local h = PAD * 2;
    if (has_main) then h = h + MAIN_H; end
    if (chain ~= nil) then h = h + SUB_GAP + CHAIN_H; end
    if (has_sub) then h = h + SUB_H + (has_main and SUB_GAP or 0); end
    return W * ctx.scale, h * ctx.scale;
end

---the main target's skillchain: its resonance names, each split into its
---elements' colours, then the window's state and seconds left, and its bar.
local function draw_chain(r, lx, rx, y, s)
    local c = theme.color;
    local waiting = clock < chain.opens;
    local col = c(waiting and 'sc_wait' or 'sc_open');
    local left = waiting and chain.opens - clock or chain.closes - clock;
    local span = waiting and chain.opens - chain.since or chain.closes - chain.opens;

    chain_time = chain_time or text.number('number');
    chain_wait = chain_wait or text.new({ text = 'wait', size = 11 });
    chain_go = chain_go or text.new({ text = 'go!', size = 11 });
    chain_time:set(('%.1f'):format(left));
    local tw, th = chain_time:size();
    local cy = y + (CHAIN_BAR_Y - 1) * 0.5 * s;
    chain_time:draw(rx, cy - th * 0.5, col, 'right');
    local state = waiting and chain_wait or chain_go;
    local _, sh = state:size();
    state:draw(rx - tw - 6 * s, cy - sh * 0.5, col, 'right');

    r.push_clip(lx, y - 2 * s, rx - lx - CHAIN_TIME_W * s, (CHAIN_BAR_Y + 2) * s);
    local nx = lx;
    for _, name in ipairs(chain.resonance) do
        local l = chain_labels[name];
        if (l == nil) then
            l = text.new({ text = name, size = 12 });
            chain_labels[name] = l;
        end
        local els = sc.ELEMENTS[name];
        local n = els and #els or 1;
        for i = 1, n do band_colors[i] = els and c(widgets.ELEMENT[els[i]]) or c('text'); end
        local _, lh = l:size();
        nx = nx + widgets.split_text(r, l, nx, cy - lh * 0.5, band_colors, n) + CHAIN_GAP * s;
    end
    r.pop_clip();

    widgets.bar(r, lx, y + CHAIN_BAR_Y * s, rx - lx, CHAIN_BAR_H * s, math.max(0, math.min(1, left / math.max(0.001, span))), col);
end

function target.draw(r, ctx, x, y)
    local w, h = target.measure(ctx);
    if (w == 0) then
        return 0, 0;
    end
    local has_main, has_sub = main.index ~= 0, sub.index ~= 0;
    local s, c = ctx.scale, theme.color;

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));
    if (locked) then
        r.nineslice('panel_glow', x, y, w, h, c('target_lock'));
    end

    local lx, rx = x + PAD * s, x + w - PAD * s;
    local my = y + PAD * s;
    local ky = my + (MAIN_H + SUB_GAP) * s; -- the chain, under the main target
    local sy = my + (has_main and (MAIN_H + SUB_GAP) or 0) * s;
    if (chain ~= nil) then sy = sy + (CHAIN_H + SUB_GAP) * s; end

    -- atlas pass
    if (has_main) then
        local frac = main.hpp / 100;
        local hpc = widgets.hp_color(frac);
        widgets.bar(r, lx, my + BAR_Y * s, rx - lx, BAR_H * s, frac, hpc, nil, trail.shown);

        main.hp_num = main.hp_num or text.number('number');
        main.dist_num = main.dist_num or text.number('number');
        main.hp_num:set(main.hpp_str);
        main.dist_num:set(main.dist_str);
        main.hp_num:draw(rx, my + NUM_Y * s, hpc, 'right');
        main.dist_num:draw(lx, my + NUM_Y * s, c('text_dim'));
    end
    if (has_sub) then
        local cy = sy + SUB_H * 0.5 * s;
        r.sprite('arrow_party', lx + 8 * s, cy, c('subtarget'));
        local frac = sub.hpp / 100;
        widgets.bar(r, rx - SUB_BAR_W * s, cy - SUB_BAR_H * 0.5 * s, SUB_BAR_W * s, SUB_BAR_H * s, frac, widgets.hp_color(frac));
    end

    if (chain ~= nil) then
        draw_chain(r, lx, rx, ky, s);
    end

    -- names last, clipped: the main name to the panel, the sub name to the
    -- space left of its bar.
    if (has_main) then
        main.name_text = main.name_text or text.new({});
        main.name_text:set(main.name);
        r.push_clip(lx, my - 2 * s, rx - lx, MAIN_H * s);
        main.name_text:draw(lx, my, main.hpp == 0 and c('text_dim') or c(main.kind));
        r.pop_clip();
    end
    if (has_sub) then
        sub.name_text = sub.name_text or text.new({});
        sub.name_text:set(sub.name);
        local nx = lx + MARK_W * s;
        r.push_clip(nx, sy - 2 * s, (rx - SUB_BAR_W * s - 6 * s) - nx, (SUB_H + 4) * s);
        sub.name_text:draw(nx, sy, sub.hpp == 0 and c('text_dim') or c(sub.kind));
        r.pop_clip();
    end

    return w, h;
end

--[[ commands ]]--

---/linhud target test - a made-up skillchain on the current target; again
---for another kind.
function target.command(ctx, args)
    if (args[1] == 'test') then
        if (main.index == 0) then return true, 'target something first'; end
        sc.test(main.sid);
        return true, 'target: added a test chain';
    end
    return false;
end

return target;
