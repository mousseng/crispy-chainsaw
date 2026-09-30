--[[
* renderer demo: a mock party list exercising every slot, clipping, gradients
* and opacity. toggled with `/linhud demo`; also rasterised by the offline tests.
--]]

local theme = require('ui.theme');

local demo = {};

local members = {
    { hp = 0.92, mp = 0.64, tp = 0.35, leader = true },
    { hp = 0.48, mp = 0.81, tp = 1.00, alliance = true },
    { hp = 0.18, mp = 0.20, tp = 0.72, sync = true },
};

---bar background, fill clipped to `frac` (keeps the chamfer on the far end
---of the track rather than squashing it), border, and a glow when full.
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

---@param r table the render module
---@param x number
---@param y number
---@param t number seconds, animates the bars so it's obviously live
function demo.draw(r, x, y, t)
    local s = theme.active().scale;
    local c = theme.color;
    local row_h, bar_w, bar_h, gap = 26 * s, 90 * s, 8 * s, 6 * s;
    local pad = 12 * s;
    local w = pad * 2 + 22 * s + bar_w * 3 + gap * 2;
    local h = pad * 2 + row_h * #members;

    r.nineslice('panel_shadow', x, y, w, h, c('shadow'));
    r.nineslice('panel', x, y, w, h, c('panel_bg'));
    r.rect(x + 1, y + 1, w - 2, 10 * s, 0x18FFFFFF, 0x00FFFFFF); -- sheen gradient
    r.nineslice('panel_border', x, y, w, h, c('panel_border'));

    for i, m in ipairs(members) do
        local ry = y + pad + (i - 1) * row_h;
        local cy = ry + row_h * 0.5;
        local wave = 0.5 + 0.5 * math.sin(t * 1.3 + i);

        if (i == 2) then
            r.sprite('arrow_party', x - 4 * s, cy, c('party_target'));
        end
        if (m.leader) then r.sprite('mark_leader', x + pad + 7 * s, cy, c('leader')); end
        if (m.alliance) then r.sprite('mark_alliance_leader', x + pad + 7 * s, cy, c('alliance_lead')); end
        if (m.sync) then r.sprite('mark_sync', x + pad + 7 * s, cy, c('sync')); end

        local bx, by = x + pad + 22 * s, cy - bar_h * 0.5;
        local hp = math.max(0.02, m.hp * (0.85 + 0.15 * wave));
        bar(r, bx, by, bar_w, bar_h, hp, hp_color(hp));
        bar(r, bx + bar_w + gap, by, bar_w, bar_h, m.mp, c('mp'));
        bar(r, bx + (bar_w + gap) * 2, by, bar_w, bar_h, m.tp, m.tp >= 1 and c('tp_full') or c('tp'));
    end

    -- target marker above the panel, fading in and out.
    r.set_opacity(0.6 + 0.4 * math.sin(t * 3));
    r.sprite('arrow_target', x + w * 0.5, y - 6 * s, c('target'));
    r.set_opacity(1);
end

return demo;
