--[[
* party list: the main party's members with hp/mp/tp, job, leader/sync marks
* and target indicators. left-clicking a member targets them.
*
* party memory is read at 10hz (it only changes when packets arrive); target
* state is read every frame so highlights follow the cursor immediately.
* strings for numbers are rebuilt only when a value changes.
--]]

local bit   = require('bit');
local text  = require('ui.text');
local theme = require('ui.theme');

local band, bor = bit.band, bit.bor;

local POLL = 0.1;          -- seconds between party memory reads
local FLAG_SYNC = 0x100;   -- member flag mask: level sync

local party = {
    name = 'party',
    defaults = { enabled = true, anchor = 'left', x = 20, y = 0, hide_solo = false },
};

-- reused member records, one per party slot.
local members = {};
for i = 0, 5 do
    members[i] = {
        slot = i, active = false, name = '', in_zone = true, target_index = 0,
        hp = 0, hpp = 0, mp = 0, mpp = 0, tp = 0,
        hp_str = '', mp_str = '', tp_str = '', job_str = '',
        leader = false, alliance_leader = false, sync = false,
        name_text = nil, hp_num = nil, mp_num = nil, tp_num = nil, job_num = nil,
    };
end
local count = 0;
local since_poll = POLL;

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

local function set_num(m, field, str_field, value)
    if (m[field] ~= value or m[str_field] == '') then
        m[field] = value;
        m[str_field] = tostring(value);
    end
end

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
            m.in_zone = p:GetMemberZone(i) == my_zone;
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
        end
    end
end

local function poll_targets()
    local t = AshitaCore:GetMemoryManager():GetTarget();
    if (t == nil) then
        target_index, subtarget_index = 0, 0;
    else
        target_index = t:GetTargetIndex(0);
        subtarget_index = t:GetIsSubTargetActive() ~= 0 and t:GetTargetIndex(1) or 0;
    end
    cursor_slot = party_cursor();
end

function party.update(ctx, dt)
    since_poll = since_poll + dt;
    if (since_poll >= POLL) then
        since_poll = 0;
        poll();
    end
    poll_targets();
end

--[[ drawing ]]--

-- layout in logical pixels. each row: name and job on top, bars, then values
-- under the bars (as ffxiv does), so nothing has to share a line with a number.
local PAD, ICON_W, ROW_H, ROW_GAP = 8, 16, 38, 2;
local HP_W, MP_W, TP_W, BAR_GAP, BAR_H, BAR_Y, NUM_Y = 104, 80, 60, 6, 7, 16, 22;

local function bar(r, x, y, w, h, frac, color)
    local c = theme.color;
    r.nineslice('bar_bg', x, y, w, h, c('bar_bg'));
    if (frac > 0) then
        r.push_clip(x, y, w * math.min(frac, 1), h);
        r.nineslice('bar', x, y, w, h, color);
        r.pop_clip();
    end
    if (frac >= 1) then
        r.nineslice('bar_glow', x, y, w, h, c('glow'));
    end
    r.nineslice('bar_border', x, y, w, h, c('bar_border'));
end

local function hp_color(frac)
    if (frac < 0.25) then return theme.color('hp_crit'); end
    if (frac < 0.5) then return theme.color('hp_low'); end
    return theme.color('hp');
end

---row geometry, shared by draw and mouse.
local function row_rect(ctx, i)
    local s = ctx.scale;
    local x, y = ctx.x, ctx.y + (PAD + i * (ROW_H + ROW_GAP)) * s;
    return x, y, ctx.w, ROW_H * s;
end

function party.draw(r, ctx, x, y)
    if (count == 0 or (count == 1 and ctx.settings.hide_solo)) then
        return 0, 0;
    end

    local s, c = ctx.scale, theme.color;
    local w = (PAD * 2 + ICON_W + HP_W + MP_W + TP_W + BAR_GAP * 2) * s;
    local h = (PAD * 2 + count * ROW_H + (count - 1) * ROW_GAP) * s;

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));

    local hx = x + (PAD + ICON_W) * s;
    local mx = hx + (HP_W + BAR_GAP) * s;
    local tx = mx + (MP_W + BAR_GAP) * s;

    -- atlas pass: everything but names, so the panel is a single draw call.
    for i = 0, count - 1 do
        local m = members[i];
        local ry = y + (PAD + i * (ROW_H + ROW_GAP)) * s;
        local by = ry + BAR_Y * s;
        local targeted = m.in_zone and m.target_index ~= 0;

        -- target / subtarget highlight behind the row
        if (targeted and m.target_index == target_index) then
            r.rect(x + 3 * s, ry - 1 * s, w - 6 * s, (ROW_H + 2) * s, c('row_target'));
        end
        if (targeted and m.target_index == subtarget_index) then
            local ox, oy, ow, oh = x + 3 * s, ry - 1 * s, w - 6 * s, (ROW_H + 2) * s;
            local sc = c('subtarget');
            r.rect(ox, oy, ow, 1 * s, sc);
            r.rect(ox, oy + oh - 1 * s, ow, 1 * s, sc);
            r.rect(ox, oy, 1 * s, oh, sc);
            r.rect(ox + ow - 1 * s, oy, 1 * s, oh, sc);
        end
        if (cursor_slot == i) then
            r.sprite('arrow_party', x - 3 * s, ry + ROW_H * 0.5 * s, c('party_target'));
        end

        -- marks: leader on the name line, sync on the bar line
        local ix = x + (PAD + ICON_W * 0.5) * s;
        if (m.alliance_leader) then
            r.sprite('mark_alliance_leader', ix, ry + 7 * s, c('alliance_lead'));
        elseif (m.leader) then
            r.sprite('mark_leader', ix, ry + 7 * s, c('leader'));
        end
        if (m.sync) then
            r.sprite('mark_sync', ix, by + BAR_H * 0.5 * s, c('sync'));
        end

        if (m.in_zone) then
            local hpc = hp_color(m.hpp);
            bar(r, hx, by, HP_W * s, BAR_H * s, m.hpp, hpc);
            bar(r, mx, by, MP_W * s, BAR_H * s, m.mpp, c('mp'));
            bar(r, tx, by, TP_W * s, BAR_H * s, math.min(m.tp, 1000) / 1000, m.tp >= 1000 and c('tp_full') or c('tp'));

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
        else
            bar(r, hx, by, HP_W * s, BAR_H * s, 0, 0);
            bar(r, mx, by, MP_W * s, BAR_H * s, 0, 0);
            bar(r, tx, by, TP_W * s, BAR_H * s, 0, 0);
        end
    end

    -- names last (one gdifonts texture each), clipped so long names can't run
    -- into the job label.
    for i = 0, count - 1 do
        local m = members[i];
        local ry = y + (PAD + i * (ROW_H + ROW_GAP)) * s;
        m.name_text = m.name_text or text.new({});
        m.name_text:set(m.name);

        local color = c('text');
        if (not m.in_zone) then
            color = c('text_dim');
        elseif (m.hp == 0) then
            color = c('hp_crit');
        end

        local job_w = m.in_zone and m.job_num and m.job_num:size() or 0;
        r.push_clip(hx, ry - 2 * s, (tx + TP_W * s) - hx - job_w - 6 * s, ROW_H * s);
        m.name_text:draw(hx, ry, color);
        r.pop_clip();
    end

    return w, h;
end

--[[ mouse ]]--

function party.mouse(ctx, ev, mx, my)
    if (ev ~= 'ldown') then return false; end
    for i = 0, count - 1 do
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
