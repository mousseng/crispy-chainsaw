--[[
* exp bar: a tab docked to the top or bottom edge of the screen, filled by
* progress to the next level, showing current / needed exp and exp per hour.
*
* the tab's long side faces whichever of the top or bottom edge it's nearer,
* decided each frame from where it's placed, so it flips as it's dragged.
*
* exp/hr is the exp gained over the last hour (or since the bar was loaded, if
* that's sooner). gains are counted from the server's exp messages rather
* than by diffing exp in memory, which can't see across a level up and
* doesn't move at all while limit points are being earned.
--]]

local render = require('ui.render');
local text   = require('ui.text');
local theme  = require('ui.theme');

local POLL     = 0.25; -- seconds between reads of exp and rate updates
local WINDOW   = 3600; -- rate is measured over the last hour...
local MIN_SPAN = 60;   -- ...but over at least a minute, so the first kill doesn't read as a huge rate
local GAP      = 8;    -- from the bar's centre to each piece of text, logical px
local MIN_W    = 280;  -- smallest width '55,999 / 56,000' fits half of, logical px

-- 0x02D (battle message) ids that report exp or limit points gained, as param 1.
local EXP_MESSAGES = { [8] = true, [105] = true, [253] = true, [371] = true, [372] = true };

local exp = {}; -- settings defaults: components/list.lua

local cur, need, frac = -1, -1, 0;
local ratio_str, rate, rate_str = '', -1, '';
local ratio_num, rate_num = nil, nil;
local since_poll = POLL;

-- gains inside the window, oldest first: a queue in parallel arrays.
local g_time, g_amount = {}, {};
local head, tail, sum = 1, 0, 0;
local started = os.clock(); -- os.clock is wall time since the client started (windows)

--[[ game state ]]--

---12345678 -> '12,345,678'
local function commas(n)
    local s = tostring(math.floor(n));
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse();
    return (out:gsub('^,', ''));
end

local function prune(now)
    local cutoff = now - WINDOW;
    while (head <= tail and g_time[head] < cutoff) do
        sum = sum - g_amount[head];
        g_time[head], g_amount[head] = nil, nil;
        head = head + 1;
    end
    if (head > tail) then head, tail, sum = 1, 0, 0; end
end

local function poll()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then return; end
    local c, n = player:GetExpCurrent(), player:GetExpNeeded();
    if (c ~= cur or n ~= need) then
        cur, need = c, n;
        frac = n > 0 and math.min(c / n, 1) or 0;
        ratio_str = ('%s / %s'):format(commas(c), commas(n));
    end

    local now = os.clock();
    prune(now);
    local span = math.max(MIN_SPAN, math.min(WINDOW, now - started));
    local r = math.floor(sum / span * 3600 + 0.5);
    if (r ~= rate) then
        rate, rate_str = r, commas(r) .. '/hr';
    end
end

function exp.update(ctx, dt)
    since_poll = since_poll + dt;
    if (since_poll >= POLL) then
        since_poll = 0;
        poll();
    end
end

function exp.packet_in(ctx, e)
    if (e.id ~= 0x02D) then return; end
    if (not EXP_MESSAGES[struct.unpack('H', e.data, 0x18 + 1) % 1024]) then return; end
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil or struct.unpack('I', e.data, 0x04 + 1) ~= party:GetMemberServerId(0)) then return; end

    local amount = struct.unpack('I', e.data, 0x10 + 1);
    tail = tail + 1;
    g_time[tail], g_amount[tail] = os.clock(), amount;
    sum = sum + amount;
    since_poll = POLL; -- show it next frame
end

--[[ commands ]]--

---/linhud exp width [n]
function exp.command(ctx, args)
    if (args[1] ~= 'width') then return false; end
    local n = tonumber(args[2]);
    if (args[2] ~= nil) then
        if (n == nil or n < MIN_W) then
            return true, ('width must be a number, at least %d'):format(MIN_W);
        end
        ctx.settings.width = math.floor(n);
    end
    return true, ('exp width: %d'):format(ctx.settings.width);
end

--[[ drawing ]]--

function exp.measure(ctx)
    if (need <= 0) then return 0, 0; end
    local _, h = render.slot_size('tab');
    return math.max(MIN_W, ctx.settings.width) * ctx.scale, h;
end

function exp.draw(r, ctx, x, y)
    local w, h = exp.measure(ctx);
    if (w == 0) then return 0, 0; end
    local s, c = ctx.scale, theme.color;

    -- long side towards the nearer of the top and bottom edges
    local flip = y + h * 0.5 < ctx.screen_h * 0.5;
    local l, _, rr = r.slot_edges('tab');
    local cx = x + w * 0.5;

    r.nineslice('tab', x, y, w, h, c('panel_bg'), flip);
    if (frac > 0) then
        -- measured along the middle of the slants, so a sliver of progress
        -- doesn't vanish into the short side's corner. full is full.
        local fw = frac >= 1 and w or (l * 0.5 + (w - (l + rr) * 0.5) * frac);
        r.push_clip(x, y, fw, h);
        r.nineslice('tab', x, y, w, h, c('exp'), flip);
        r.pop_clip();
    end
    r.nineslice('tab_border', x, y, w, h, c('panel_border'), flip);

    ratio_num = ratio_num or text.number('exp');
    rate_num = rate_num or text.number('exp');
    ratio_num:set(ratio_str);
    rate_num:set(rate_str);
    local _, th = ratio_num:size();
    local ty = y + (h - th) * 0.5;

    -- either side of the centre, split by a dot. clipped to the tab's
    -- straight middle in case a narrow bar can't fit them.
    local cy = y + h * 0.5;
    r.sprite('dot', cx, cy, 0xFF000000, 2.5); -- outline, like the glyphs'
    r.sprite('dot', cx, cy, c('text_dim'));
    r.push_clip(x + l, y, w - l - rr, h);
    ratio_num:draw(cx - GAP * s, ty, c('text'), 'right');
    rate_num:draw(cx + GAP * s, ty, c('text'));
    r.pop_clip();

    return w, h;
end

return exp;
