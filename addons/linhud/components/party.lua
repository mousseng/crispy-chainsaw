--[[
* party list: the main party's members with hp/mp/tp, job, leader/sync marks,
* status effects and target indicators. left-clicking a member targets them.
*
* party memory is read at 10hz (it only changes when packets arrive); target
* state is read every frame so highlights follow the cursor immediately.
* strings for numbers are rebuilt only when a value changes.
*
* status icons sit under a member's bars, wrapping onto as many lines as they
* need up to settings.status_lines (`/linhud party status <n>`; 0 hides
* them); any past that are left off. a member with none takes no extra room.
--]]

local bit     = require('bit');
local targets = require('game.targets');
local icons   = require('ui.icons');
local text    = require('ui.text');
local theme   = require('ui.theme');
local widgets = require('ui.widgets');

local band, bor, rshift = bit.band, bit.bor, bit.rshift;
local floor, ceil, min = math.floor, math.ceil, math.min;
local read_u8, read_u32 = ashita.memory.read_uint8, ashita.memory.read_uint32;

local POLL = 0.1;          -- seconds between party memory reads
local FLAG_SYNC = 0x100;   -- member flag mask: level sync
local MAX_STATUS = 32;     -- status effects the client tracks per member
local NO_STATUS = 255;     -- an empty status slot

-- the other members' status effects (the player's own are in IPlayer): five
-- 0x30-byte entries, in no particular order, each a server id, the high two
-- bits of each of 32 status ids packed into 8 bytes at +8, and their low
-- bytes at +16.
local status_ptr = AshitaCore:GetPointerManager():Get('party.statusicons');

local party = {}; -- settings defaults: components/list.lua

-- reused member records, one per party slot.
local members = {};
for i = 0, 5 do
    members[i] = {
        slot = i, active = false, name = '', in_zone = true, target_index = 0,
        hp = 0, hpp = 0, mp = 0, mpp = 0, tp = 0,
        hp_str = '', mp_str = '', tp_str = '', job_str = '',
        zone_id = -1, zone_str = '',
        leader = false, alliance_leader = false, sync = false,
        status = {}, nstatus = 0, status_lines = 0,
        name_text = nil, zone_text = nil, hp_num = nil, mp_num = nil, tp_num = nil, job_num = nil,
        -- bar trails (tp's as a fraction of 3000); fresh: jump them to the
        -- current values rather than animate from whoever was here before.
        sid = 0, fresh = true,
        hp_trail = widgets.trail_new(), mp_trail = widgets.trail_new(), tp_trail = widgets.trail_new(),
    };
end
local count = 0;
local since_poll = POLL;
local clock = 0; -- seconds into the tp gradient's scroll cycle

-- tp past 1000 is a second bar layer: a gradient of tp_over and tp_over_alt
-- scrolling along it.
local TP_SCROLL = 2; -- seconds for the gradient to move one bar width

-- target state, read every frame.
local target_index, subtarget_index, cursor_slot = 0, 0, nil;

--[[ game state ]]--

---the <stpt> party cursor (which member is being picked), or nil.
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

local function job_label(p, i)
    local res = AshitaCore:GetResourceManager();
    local main, sub = p:GetMemberMainJob(i), p:GetMemberSubJob(i);
    local mj = main > 0 and res:GetString('jobs.names_abbr', main) or nil;
    if (mj == nil or mj == '') then return ''; end
    local s = mj .. p:GetMemberMainJobLevel(i);
    local sj = sub > 0 and res:GetString('jobs.names_abbr', sub) or nil;
    if (sj ~= nil and sj ~= '') then
        s = s .. '/' .. sj .. p:GetMemberSubJobLevel(i);
    end
    return s;
end

---zone name for out-of-zone members; looked up only when the zone changes.
local function set_zone(m, zone)
    if (m.zone_id == zone) then return; end
    m.zone_id = zone;
    local name = zone > 0 and AshitaCore:GetResourceManager():GetString('zones.names', zone) or nil;
    m.zone_str = (name ~= nil and name ~= '') and name or '';
end

local function set_num(m, field, str_field, value)
    if (m[field] ~= value or m[str_field] == '') then
        m[field] = value;
        m[str_field] = tostring(value);
    end
end

local function read_player_status(m)
    local buffs = AshitaCore:GetMemoryManager():GetPlayer():GetBuffs();
    local n = 0;
    for k = 1, MAX_STATUS do
        local id = buffs[k];
        if (id ~= nil and id >= 0 and id ~= NO_STATUS) then
            n = n + 1;
            m.status[n] = id;
        end
    end
    m.nstatus = n;
end

local function read_member_status(m, sid)
    m.nstatus = 0;
    if (status_ptr == nil or status_ptr == 0 or sid == 0) then return; end
    local base = read_u32(status_ptr);
    if (base == 0) then return; end
    for e = base, base + 4 * 0x30, 0x30 do
        if (read_u32(e) == sid) then
            local n, hi = 0, 0;
            for b = 0, MAX_STATUS - 1 do
                if (b % 4 == 0) then hi = read_u8(e + 8 + rshift(b, 2)); end
                local id = band(rshift(hi, (b % 4) * 2), 3) * 256 + read_u8(e + 16 + b);
                if (id ~= NO_STATUS) then
                    n = n + 1;
                    m.status[n] = id;
                end
            end
            m.nstatus = n;
            return;
        end
    end
end

local trail_reset, trail_step = widgets.trail_reset, widgets.trail_step;

local function poll()
    local p = AshitaCore:GetMemoryManager():GetParty();
    if (p == nil) then count = 0; return; end

    local my_zone = p:GetMemberZone(0);
    local party_leader = p:GetAlliancePartyLeaderServerId1();
    local alliance_leader = p:GetAllianceLeaderServerId();
    local in_alliance = p:GetAlliancePartyMemberCount2() > 0 or p:GetAlliancePartyMemberCount3() > 0;

    count = 0;
    for i = 0, 5 do
        local m = members[i];
        m.active = p:GetMemberIsActive(i) ~= 0;
        if (m.active) then
            count = i + 1;
            local sid = p:GetMemberServerId(i);
            m.name = p:GetMemberName(i);
            local zone = p:GetMemberZone(i);
            local was_in_zone = m.in_zone;
            m.in_zone = zone == my_zone;
            if (sid ~= m.sid or not was_in_zone) then
                m.sid, m.fresh = sid, true;
            end
            set_zone(m, zone);
            m.target_index = m.in_zone and p:GetMemberTargetIndex(i) or 0;
            m.leader = sid ~= 0 and sid == party_leader;
            m.alliance_leader = in_alliance and sid ~= 0 and sid == alliance_leader;
            m.sync = band(p:GetMemberFlagMask(i), FLAG_SYNC) ~= 0;
            set_num(m, 'hp', 'hp_str', p:GetMemberHP(i));
            set_num(m, 'mp', 'mp_str', p:GetMemberMP(i));
            set_num(m, 'tp', 'tp_str', p:GetMemberTP(i));
            m.hpp = p:GetMemberHPPercent(i) / 100;
            m.mpp = p:GetMemberMPPercent(i) / 100;
            m.job_str = m.in_zone and job_label(p, i) or '';
            if (i == 0) then
                read_player_status(m);
            elseif (m.in_zone) then
                read_member_status(m, sid);
            else
                m.nstatus = 0; -- only reported for members in our zone
            end
        else
            m.sid = 0; -- whoever joins this slot next starts fresh, even if it's them again
        end
    end
end

local function poll_targets()
    target_index, subtarget_index = targets.indices();
    cursor_slot = party_cursor();
end

---moves each member's bar trails. hp and mp trail both ways; tp only
---trails drops (a weaponskill), since it rises on every swing.
local function step_trails(dt)
    for i = 0, count - 1 do
        local m = members[i];
        local tpf = m.tp / 3000;
        if (m.fresh) then
            m.fresh = false;
            trail_reset(m.hp_trail, m.hpp);
            trail_reset(m.mp_trail, m.mpp);
            trail_reset(m.tp_trail, tpf);
        else
            trail_step(m.hp_trail, m.hpp, dt, true);
            trail_step(m.mp_trail, m.mpp, dt, true);
            trail_step(m.tp_trail, tpf, dt, false);
        end
    end
end

function party.update(ctx, dt)
    since_poll = since_poll + dt;
    clock = (clock + dt) % TP_SCROLL;
    if (since_poll >= POLL) then
        since_poll = 0;
        poll();
    end
    step_trails(dt);
    poll_targets();
end

--[[ drawing ]]--

-- layout in logical pixels. each row: name and job on top, bars, then values
-- under the bars (as ffxiv does), so nothing has to share a line with a number.
local PAD, ROW_H, ROW_GAP = 8, 40, 2;
local TARGET_OUT = 2; -- how far the target highlight extends past the row's inset
-- leader / sync marks sit before the name like leading glyphs: their centre
-- line, and the gap after each.
local MARK_Y, MARK_GAP = 7, 3;
local HP_W, MP_W, TP_W, BAR_GAP, BAR_H, BAR_Y, NUM_Y = 104, 80, 60, 6, 7, 17, 23;
-- status icons: lines of them under the bars, as wide as the bars.
local STATUS_S, STATUS_GAP, STATUS_Y = 16, 2, ROW_H - 1;
local PER_LINE = floor((HP_W + MP_W + TP_W + BAR_GAP * 2 + STATUS_GAP) / (STATUS_S + STATUS_GAP));

local bar, hp_color = widgets.bar, widgets.hp_color;

-- each row's top and height in logical pixels, from the panel's top; rows
-- grow to fit their status icons. set by layout().
local row_y, row_h = {}, {};

---lays the rows out. returns the panel's logical height.
local function layout(ctx)
    local max_lines = ctx.settings.status_lines or 2;
    local y = PAD;
    for i = 0, count - 1 do
        local m = members[i];
        m.status_lines = min(ceil(m.nstatus / PER_LINE), max_lines);
        row_y[i], row_h[i] = y, ROW_H + m.status_lines * (STATUS_S + STATUS_GAP);
        y = y + row_h[i] + ROW_GAP;
    end
    return y - ROW_GAP + PAD;
end

---row geometry, shared by draw and mouse.
local function row_rect(ctx, i)
    local s = ctx.scale;
    return ctx.x, ctx.y + row_y[i] * s, ctx.w, row_h[i] * s;
end

function party.measure(ctx)
    if (count == 0 or (count == 1 and ctx.settings.hide_solo)) then
        return 0, 0;
    end
    local s = ctx.scale;
    return (PAD * 2 + HP_W + MP_W + TP_W + BAR_GAP * 2) * s, layout(ctx) * s;
end

function party.command(ctx, args)
    if (args[1] ~= 'status') then return false; end
    local n = tonumber(args[2]);
    if (args[2] ~= nil) then
        if (n == nil or n < 0) then
            return true, 'status lines must be a number, 0 or more';
        end
        ctx.settings.status_lines = floor(n);
    end
    return true, ('party status lines: %d (%d icons each)'):format(ctx.settings.status_lines or 2, PER_LINE);
end

---draws a mark sprite with its left edge at x, centred on cy. returns the x
---the next mark (or the name) starts at.
local function mark(r, name, x, cy, color, s)
    local w = r.slot_size(name);
    if (w == 0) then return x; end
    local px = theme.slot(name).pivot[1];
    r.sprite(name, x + w * px, cy, color);
    return x + w + MARK_GAP * s;
end

function party.draw(r, ctx, x, y)
    local w, h = party.measure(ctx);
    if (w == 0) then
        return 0, 0;
    end

    local s, c = ctx.scale, theme.color;

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));

    local hx = x + PAD * s;
    local tp_phase = clock / TP_SCROLL;
    local mx = hx + (HP_W + BAR_GAP) * s;
    local tx = mx + (MP_W + BAR_GAP) * s;

    -- atlas pass: everything but names, so the panel is a single draw call.
    for i = 0, count - 1 do
        local m = members[i];
        local ry = y + row_y[i] * s;
        local by = ry + BAR_Y * s;
        local targeted = m.in_zone and m.target_index ~= 0;

        -- target / subtarget highlight behind the row, inset from the panel's
        -- edge. the target's fades out across the first two thirds of the row.
        -- a gradient only has stops at vertices, and the nineslice's stretched
        -- middle spans nearly the whole row, so clip it to where the fade ends
        -- (which puts vertices there) and draw the rest in the end colour.
        local hx0, hy0, hw, hh = x + 6 * s, ry + 2 * s, w - 12 * s, (row_h[i] - 4) * s;
        if (targeted and m.target_index == target_index) then
            -- grown by TARGET_OUT so it clears the row's contents
            local o = TARGET_OUT * s;
            local tx0, ty0, tw, th = hx0 - o, hy0 - o, hw + 2 * o, hh + 2 * o;
            local fw = tw * 0.66;
            r.push_clip(tx0, ty0, fw, th);
            r.nineslice_hgrad('row_highlight', tx0, ty0, tw, th, c('row_target'), c('row_target_fade'), tx0, tx0 + fw);
            r.pop_clip();
            r.push_clip(tx0 + fw, ty0, tw - fw, th);
            r.nineslice('row_highlight', tx0, ty0, tw, th, c('row_target_fade'));
            r.pop_clip();
        end
        if (targeted and m.target_index == subtarget_index) then
            r.nineslice('panel_border', hx0 - 2 * s, hy0 - 2 * s, hw + 4 * s, hh + 4 * s, c('subtarget'));
        end
        if (cursor_slot == i) then
            r.sprite('arrow_party', x - 3 * s, ry + ROW_H * 0.5 * s, c('party_target'));
        end

        -- marks lead the name; each pushes it right. the name is drawn at
        -- m.name_x in the text pass.
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

        if (m.in_zone) then
            local hpc = hp_color(m.hpp);
            -- critical hp glows red; not when dead, where it would just outline an empty bar.
            bar(r, hx, by, HP_W * s, BAR_H * s, m.hpp, hpc, (m.hpp < 0.25 and m.hp > 0) and c('hp_crit') or nil, m.hp_trail.shown);
            bar(r, mx, by, MP_W * s, BAR_H * s, m.mpp, c('mp'), nil, m.mp_trail.shown);
            -- 0..1000 fills the bar; 1000..3000 fills a second layer over it.
            -- the trail splits the same way, so a weaponskill's loss shows on both.
            local full, tps = m.tp >= 1000, m.tp_trail.shown * 3000;
            bar(r, tx, by, TP_W * s, BAR_H * s, min(m.tp, 1000) / 1000, full and c('tp_full') or c('tp'), full and c('tp_full') or nil,
                min(tps, 1000) / 1000, (m.tp - 1000) / 2000, c('tp_over'), c('tp_over_alt'), tp_phase, (tps - 1000) / 2000);

            m.hp_num = m.hp_num or text.number('number');
            m.mp_num = m.mp_num or text.number('number');
            m.tp_num = m.tp_num or text.number('number');
            m.job_num = m.job_num or text.number('job');
            m.hp_num:set(m.hp_str);
            m.mp_num:set(m.mp_str);
            m.tp_num:set(m.tp_str);
            m.job_num:set(m.job_str);
            local ny = ry + NUM_Y * s;
            m.hp_num:draw(hx + HP_W * s, ny, hpc, 'right');
            m.mp_num:draw(mx + MP_W * s, ny, c('text'), 'right');
            m.tp_num:draw(tx + TP_W * s, ny, m.tp >= 1000 and c('tp_full') or c('text'), 'right');
            m.job_num:draw(tx + TP_W * s, ry + 3 * s, c('text_dim'), 'right');
        end
        -- out of zone: the zone name replaces the bars (drawn in the text pass)
    end

    -- status icons: their own sheet, so one more draw call for the panel.
    local ss, step = STATUS_S * s, (STATUS_S + STATUS_GAP) * s;
    for i = 0, count - 1 do
        local m = members[i];
        local n = min(m.nstatus, m.status_lines * PER_LINE);
        local sy = y + (row_y[i] + STATUS_Y) * s;
        for k = 0, n - 1 do
            icons.status(r, m.status[k + 1], hx + (k % PER_LINE) * step, sy + floor(k / PER_LINE) * step, ss);
        end
    end

    -- names and zone names last (one gdifonts texture each), clipped so long
    -- names can't run into the job label.
    for i = 0, count - 1 do
        local m = members[i];
        local ry = y + row_y[i] * s;
        m.name_text = m.name_text or text.new({});
        m.name_text:set(m.name);

        local color = c('text');
        if (not m.in_zone) then
            color = c('text_dim');
        elseif (m.hp == 0) then
            color = c('hp_crit');
        end

        local nx = m.name_x or hx;
        local job_w = m.in_zone and m.job_num and m.job_num:size() or 0;
        r.push_clip(nx, ry - 2 * s, (tx + TP_W * s) - nx - job_w - 6 * s, ROW_H * s);
        m.name_text:draw(nx, ry, color);
        r.pop_clip();

        if (not m.in_zone and m.zone_str ~= '') then
            m.zone_text = m.zone_text or text.new({ size = 12, bold = false });
            m.zone_text:set(m.zone_str);
            r.push_clip(hx, ry, (tx + TP_W * s) - hx, ROW_H * s);
            m.zone_text:draw(hx, ry + (BAR_Y - 2) * s, c('text_dim'));
            r.pop_clip();
        end
    end

    return w, h;
end

--[[ mouse ]]--

function party.mouse(ctx, ev, mx, my)
    if (ev ~= 'ldown') then return false; end
    for i = 0, count - 1 do
        if (row_y[i] == nil) then break; end -- not laid out yet
        local _, ry, _, rh = row_rect(ctx, i);
        local top = ry - ctx.y;
        if (my >= top and my < top + rh and members[i].active) then
            AshitaCore:GetChatManager():QueueCommand(1, ('/ta <p%d>'):format(i));
            return true;
        end
    end
    return false;
end

return party;
