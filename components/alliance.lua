--[[
* alliance panels: one of the other two parties in the alliance, condensed to
* a name (with leader / sync marks) over an hp bar per member. target,
* subtarget and party cursor highlights work as in the party list, and
* left-clicking a member targets them.
*
* not a component itself: components/alliance1.lua and alliance2.lua each
* make a panel with new(), for the alliance's second and third parties (party
* slots 6..11 and 12..17). each panel keeps its own state, so the two can be
* placed and toggled apart. a panel with nobody in its party draws nothing.
--]]

local bit     = require('bit');
local targets = require('game.targets');
local text    = require('ui.text');
local theme   = require('ui.theme');
local widgets = require('ui.widgets');

local band = bit.band;

local POLL = 0.1;        -- seconds between party memory reads
local FLAG_SYNC = 0x100; -- member flag mask: level sync

-- layout in logical pixels: the name on top, an hp bar under it. the name,
-- zone name and bar are the party list's sizes, just without its mp / tp
-- columns and numbers.
local PAD, ROW_H, ROW_GAP = 6, 28, 2;
local BAR_W, BAR_H, BAR_Y = 104, 7, 17;
local ZONE_FONT, ZONE_Y = 12, 13;
local TARGET_OUT = 2; -- how far the target highlight extends past the row's inset
local MARK_Y, MARK_GAP = 7, 3; -- the marks' centre line, and the gap after each
local SPIN_PERIOD, SPIN_TAIL = 2.5, 0.3; -- as the party list's

local trail_reset, trail_step = widgets.trail_reset, widgets.trail_step;
local bar = widgets.bar;

---the in-game party list's bands, as the party list draws them.
local function hp_color(frac)
    if (frac <= 0.25) then return theme.color('hp_crit'); end
    if (frac <= 0.5) then return theme.color('hp_warn'); end
    if (frac <= 0.75) then return theme.color('hp_low'); end
    return theme.color('hp');
end

---the <stpt> / <stal> party cursor (which alliance slot, 0..17, is being
---picked), or nil.
local function party_cursor()
    local ptr = AshitaCore:GetPointerManager():Get('party');
    if (ptr == nil or ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    ptr = ashita.memory.read_uint32(ptr);
    if (ptr == 0) then return nil; end
    if (ashita.memory.read_uint32(ptr + 0x54) == 0) then return nil; end
    return ashita.memory.read_uint8(ptr + 0x50);
end

---zone name for out-of-zone members; looked up only when the zone changes.
local function set_zone(m, zone)
    if (m.zone_id == zone) then return; end
    m.zone_id = zone;
    local name = zone > 0 and AshitaCore:GetResourceManager():GetString('zones.names', zone) or nil;
    m.zone_str = (name ~= nil and name ~= '') and name or '';
end

---draws a mark sprite with its left edge at x, centred on cy. returns the x
---the next mark (or the name) starts at.
local function mark(r, name, x, cy, color, s)
    local w = r.slot_size(name);
    if (w == 0) then return x; end
    r.sprite(name, x + w * theme.slot(name).pivot[1], cy, color);
    return x + w + MARK_GAP * s;
end

local alliance = {};

---@param n integer 1 or 2: which of the other parties (the alliance's second or third)
function alliance.new(n)
    local first = n * 6; -- the party's first slot in party memory
    local leader_id = n == 1
        and function (p) return p:GetAlliancePartyLeaderServerId2(); end
        or function (p) return p:GetAlliancePartyLeaderServerId3(); end;

    -- reused member records, one per slot in the party.
    local members = {};
    for k = 0, 5 do
        members[k] = {
            slot = first + k, name = '', in_zone = true, target_index = 0,
            hp = 0, hpp = 0, leader = false, alliance_leader = false, sync = false,
            sid = 0, fresh = true, trail = widgets.trail_new(), name_text = nil, name_x = 0,
            zone_id = -1, zone_str = '', zone_text = nil,
        };
    end
    -- the active members' records, in slot order; count of them.
    local rows, count = {}, 0;
    local since_poll, spin = POLL, 0;
    local target_index, subtarget_index, cursor_slot = 0, 0, nil;

    local function poll()
        local p = AshitaCore:GetMemoryManager():GetParty();
        count = 0;
        if (p == nil) then return; end
        local my_zone = p:GetMemberZone(0);
        local party_leader, alliance_leader = leader_id(p), p:GetAllianceLeaderServerId();
        for k = 0, 5 do
            local m = members[k];
            local i = m.slot;
            if (p:GetMemberIsActive(i) ~= 0) then
                count = count + 1;
                rows[count] = m;
                local sid = p:GetMemberServerId(i);
                local was_in_zone = m.in_zone;
                local zone = p:GetMemberZone(i);
                m.in_zone = zone == my_zone;
                set_zone(m, zone);
                if (sid ~= m.sid or not was_in_zone) then
                    m.sid, m.fresh = sid, true;
                end
                m.name = p:GetMemberName(i);
                m.target_index = m.in_zone and p:GetMemberTargetIndex(i) or 0;
                m.leader = sid ~= 0 and sid == party_leader;
                m.alliance_leader = sid ~= 0 and sid == alliance_leader;
                m.sync = band(p:GetMemberFlagMask(i), FLAG_SYNC) ~= 0;
                m.hp = p:GetMemberHP(i);
                m.hpp = p:GetMemberHPPercent(i) / 100;
            else
                m.sid = 0; -- whoever joins this slot next starts fresh
            end
        end
    end

    local function step_trails(dt)
        for j = 1, count do
            local m = rows[j];
            if (m.fresh) then
                m.fresh = false;
                trail_reset(m.trail, m.hpp);
            else
                trail_step(m.trail, m.hpp, dt, true);
            end
        end
    end

    local panel = {};

    function panel.update(ctx, dt)
        since_poll = since_poll + dt;
        spin = (spin + dt) % SPIN_PERIOD;
        if (since_poll >= POLL) then
            since_poll = 0;
            poll();
        end
        if (count == 0) then return; end
        step_trails(dt);
        target_index, subtarget_index = targets.indices();
        cursor_slot = party_cursor();
    end

    function panel.measure(ctx)
        if (count == 0) then return 0, 0; end
        local s = ctx.scale;
        return (PAD * 2 + BAR_W) * s, (PAD * 2 + count * (ROW_H + ROW_GAP) - ROW_GAP) * s;
    end

    function panel.draw(r, ctx, x, y)
        local w, h = panel.measure(ctx);
        if (w == 0) then return 0, 0; end

        local s, c = ctx.scale, theme.color;
        r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
        r.nineslice('panel', x, y, w, h, c('panel_bg'));
        r.nineslice('panel_border', x, y, w, h, c('panel_border'));

        local hx = x + PAD * s;
        local o = TARGET_OUT * s;
        local pos = spin / SPIN_PERIOD;

        -- atlas pass: highlights, marks and bars.
        for j = 1, count do
            local m = rows[j];
            local ry = y + (PAD + (j - 1) * (ROW_H + ROW_GAP)) * s;
            local targeted = m.in_zone and m.target_index ~= 0;

            local tx0, ty0, tw, th = x + 4 * s - o, ry - o, w - 8 * s + 2 * o, ROW_H * s + 2 * o;
            if (targeted and m.target_index == target_index) then
                local spin_c = c('row_target_spin');
                widgets.spinner(r, 'row_highlight', tx0, ty0, tw, th, spin_c, pos, SPIN_TAIL);
                widgets.spinner(r, 'row_highlight', tx0, ty0, tw, th, spin_c, pos + 0.5, SPIN_TAIL);
            end
            if ((targeted and m.target_index == subtarget_index) or cursor_slot == m.slot) then
                local spin_c = c('row_subtarget_spin');
                widgets.spinner(r, 'row_highlight', tx0, ty0, tw, th, spin_c, pos + 0.25, SPIN_TAIL);
                widgets.spinner(r, 'row_highlight', tx0, ty0, tw, th, spin_c, pos + 0.75, SPIN_TAIL);
            end

            local nx, my = hx, ry + MARK_Y * s;
            if (m.alliance_leader) then
                nx = mark(r, 'mark_alliance_leader', nx, my, c('alliance_lead'), s);
            elseif (m.leader) then
                nx = mark(r, 'mark_leader', nx, my, c('leader'), s);
            end
            if (m.sync) then
                nx = mark(r, 'mark_sync', nx, my, c('sync'), s);
            end
            m.name_x = nx;

            -- out of zone: the client has no hp for them, so the zone name
            -- (drawn in the text pass) takes the bar's place and the name dims.
            if (m.in_zone) then
                bar(r, hx, ry + BAR_Y * s, BAR_W * s, BAR_H * s, m.hpp, hp_color(m.hpp),
                    (m.hpp <= 0.25 and m.hp > 0) and c('hp_crit') or nil, m.trail.shown);
            end
        end

        -- names and zone names last (one gdifonts texture each), clipped to
        -- the bar's width.
        for j = 1, count do
            local m = rows[j];
            local ry = y + (PAD + (j - 1) * (ROW_H + ROW_GAP)) * s;
            m.name_text = m.name_text or text.new({});
            m.name_text:set(m.name);
            local color = c('text');
            if (not m.in_zone) then
                color = c('text_dim');
            elseif (m.hp == 0) then
                color = c('hp_crit');
            end
            r.push_clip(m.name_x, ry - 2 * s, hx + BAR_W * s - m.name_x, ROW_H * s);
            m.name_text:draw(m.name_x, ry, color);
            r.pop_clip();

            if (not m.in_zone and m.zone_str ~= '') then
                m.zone_text = m.zone_text or text.new({ size = ZONE_FONT, bold = false });
                m.zone_text:set(m.zone_str);
                r.push_clip(hx, ry, BAR_W * s, (ROW_H + ROW_GAP) * s);
                m.zone_text:draw(hx, ry + ZONE_Y * s, c('text_dim'));
                r.pop_clip();
            end
        end

        return w, h;
    end

    function panel.mouse(ctx, ev, mx, my)
        if (ev ~= 'ldown' or count == 0) then return false; end
        local j = math.floor((my / ctx.scale - PAD) / (ROW_H + ROW_GAP)) + 1;
        if (j < 1 or j > count) then return false; end
        -- <a20>..<a25> is the alliance's second party, <a30>..<a35> its third.
        AshitaCore:GetChatManager():QueueCommand(1, ('/ta <a%d%d>'):format(n + 1, rows[j].slot - first));
        return true;
    end

    return panel;
end

return alliance;
