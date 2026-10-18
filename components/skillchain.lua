--[[
* skillchain: the chain going on the current target (or, without one, the
* party's latest) as text straight over the game, with no panel.
*
* a header says where the chain stands: "Chance!" while it's only open (a
* weaponskill landed, nothing to burst yet), "Skillchain!" once a skillchain
* has closed it. then each step in turn: every weaponskill (or chaining spell
* or monster ability) and its damage, and nested beneath it the skillchain it
* made and that skillchain's magic bursts. last, the window's countdown (wait,
* then go) and, see-through, the properties that could carry the chain on;
* once the window closes, "fin", and the chain fades out (game/skillchain.lua
* keeps it LINGER seconds).
*
* the header, skillchain names, "Burst!" and "fin" are in the theme's
* decorative font and the figures in its numeral font, both from atlas glyph
* sets (sc_title, sc_deco, sc_num); weaponskill and spell names are in the
* regular font. skillchain names are split into their elements' colours.
*
* only shown while there's a chain, or while the hud is unlocked, so it can be
* placed. `/cc skillchain demo` plays a made-up chain on the current target
* (or on nothing, without one).
--]]

local hud     = require('ui.hud');
local sc      = require('game.skillchain');
local targets = require('game.targets');
local text    = require('ui.text');
local theme   = require('ui.theme');
local widgets = require('ui.widgets');

local skillchain = {}; -- settings defaults: components/list.lua

-- layout, logical px. steps' skillchains and bursts sit INDENT in; the
-- combos wrap at W. rows stack at LEADING times their text's line height: a
-- line counts the font's whole ascent and descent, mostly empty space here.
local W, INDENT, GAP, ROW_GAP = 280, 16, 6, 0;
local LEADING = 0.78;
local NAME_SIZE, SMALL_SIZE = 13, 12; -- weaponskill / spell names; the countdown and combos
local SHOWN = 4;    -- steps shown, the latest
local FADE = 1;     -- seconds the chain fades out over, at the end of its linger
local LABELS = 96;  -- regular-font names kept before the cache starts over

-- measure only, or draw atlas text, or draw the regular font's (each name its
-- own texture, so after the atlas rather than interleaved with it)
local MEASURE, ATLAS, LABEL = 0, 1, 2;

local chain = nil; -- the record shown, from game/skillchain.lua
local clock = 0;
local alpha = 1;

--[[ text ]]--

local EMPTY = {};
local labels, nlabels = {}, 0;          -- size .. '|' .. name -> regular-font text
local glyph_text = {};                  -- set .. '|' .. str -> atlas text
local figures = setmetatable({}, { __mode = 'k' }); -- step / skillchain / burst -> its damage, formatted
local band_colors = {};
local timer, timer_ref, timer_tenths, lbl_wait, lbl_go = nil, nil, -1, nil, nil;

---regular-font text for a name, made the first time it's asked for.
local function label(str, size)
    local key = size .. '|' .. str;
    local l = labels[key];
    if (l == nil) then
        if (nlabels >= LABELS) then labels, nlabels = {}, 0; end
        l = text.new({ text = str, size = size });
        labels[key], nlabels = l, nlabels + 1;
    end
    return l;
end

---a fixed string from atlas glyph set `set`.
local function glyphs(set, str)
    local key = set .. '|' .. str;
    local g = glyph_text[key];
    if (g == nil) then
        g = text.number(set);
        g:set(str);
        glyph_text[key] = g;
    end
    return g;
end

local function commas(n)
    local s, k = tostring(math.floor(n)), 0;
    repeat s, k = s:gsub('^(%d+)(%d%d%d)', '%1,%2'); until k == 0;
    return s;
end

---the damage of `t` (anything with a `dmg`) in the numeral font, or nil if
---it has none.
local function figure(t)
    if (t.dmg == nil) then return nil; end
    local f = figures[t];
    if (f == nil) then
        f = text.number('sc_num');
        f:set(commas(t.dmg));
        figures[t] = f;
    end
    return f;
end

---theme colour `key`.
local function col(key)
    return theme.color(key);
end

--[[ rows ]]--

-- each row hangs from one baseline, as far down as its tallest text needs;
-- these return the row's height and draw only in the matching pass.

---the height of a row of texts a, b, c (b and c may be nil) around one
---baseline, tightened by LEADING.
---@return number ascent, number height
local function metrics(a, b, c)
    local asc, line = a:baseline();
    local dep = line - asc;
    if (b ~= nil) then
        local b2, l2 = b:baseline();
        if (b2 > asc) then asc = b2; end
        if (l2 - b2 > dep) then dep = l2 - b2; end
    end
    if (c ~= nil) then
        local b2, l2 = c:baseline();
        if (b2 > asc) then asc = b2; end
        if (l2 - b2 > dep) then dep = l2 - b2; end
    end
    return asc, (asc + dep) * LEADING;
end

---t with its baseline at `base`, if this is its pass. returns its width.
local function put(t, x, base, color, pass, want)
    if (pass == want) then t:draw(x, base - t:baseline(), color); end
    return (t:size());
end

local function header(r, pass, x, y, str, color)
    local t = glyphs('sc_title', str);
    local asc, h = metrics(t);
    put(t, x, y + asc, color, pass, ATLAS);
    return h;
end

---a weaponskill: its name, then its damage.
local function ws_row(r, pass, x, y, s, step)
    local name, dmg = label(step.name, NAME_SIZE), figure(step);
    local asc, h = metrics(name, dmg);
    local base = y + asc;
    local w = put(name, x, base, col('text'), pass, LABEL);
    if (dmg ~= nil) then put(dmg, x + w + GAP * s, base, col('text'), pass, ATLAS); end
    return h;
end

---a skillchain: its name in its elements' colours, then its damage.
local function sc_row(r, pass, x, y, s, step)
    local name, dmg = glyphs('sc_deco', step.name), figure(step);
    local asc, h = metrics(name, dmg);
    local base = y + asc;
    local w = (name:size());
    if (pass == ATLAS) then
        local els = sc.ELEMENTS[step.name];
        local n = els and #els or 1;
        for i = 1, n do band_colors[i] = els and col(widgets.ELEMENT[els[i]]) or col('text'); end
        widgets.split_text(r, name, x, base - name:baseline(), band_colors, n);
    end
    if (dmg ~= nil) then put(dmg, x + w + GAP * s, base, col('text'), pass, ATLAS); end
    return h;
end

---a magic burst: "Burst!", the spell, then its damage if it did any.
local function burst_row(r, pass, x, y, s, b)
    local lead, name, dmg = glyphs('sc_deco', 'Burst!'), label(b.name, NAME_SIZE), figure(b);
    local asc, h = metrics(lead, name, dmg);
    local base = y + asc;
    x = x + put(lead, x, base, col('sc_burst'), pass, ATLAS) + GAP * s;
    x = x + put(name, x, base, col('text'), pass, LABEL) + GAP * s;
    if (dmg ~= nil) then put(dmg, x, base, col('text'), pass, ATLAS); end
    return h;
end

---the window's countdown (wait, then go) and what can follow, wrapping at
---the component's width under where the first began.
local function next_row(r, pass, x, y, s)
    local waiting = clock < chain.opens;
    local tc = col(waiting and 'sc_wait' or 'sc_open');
    lbl_wait = lbl_wait or text.new({ text = 'wait', size = SMALL_SIZE });
    lbl_go = lbl_go or text.new({ text = 'go', size = SMALL_SIZE });
    timer = timer or text.number('sc_num');
    timer_ref = timer_ref or text.number('sc_num');
    timer_ref:set('00.0');
    local tenths = math.max(0, math.ceil(((waiting and chain.opens or chain.closes) - clock) * 10));
    if (tenths ~= timer_tenths) then
        timer_tenths = tenths;
        timer:set(('%.1f'):format(tenths / 10));
    end

    local state = waiting and lbl_wait or lbl_go;
    local combos = sc.combos(chain.resonance or EMPTY);
    local first = combos[1] and label(combos[1], SMALL_SIZE) or nil;
    local asc, h = metrics(state, timer, first);
    local base = y + asc;
    local sw = math.max((lbl_wait:size()), (lbl_go:size()));
    put(state, x, base, tc, pass, LABEL);
    put(timer, x + sw + GAP * s, base, tc, pass, ATLAS);

    -- fixed columns, so the names don't shift as the figures tick
    local cx0 = x + sw + GAP * s + (timer_ref:size()) + GAP * 2 * s;
    local cx, right, lines = cx0, x + W * s, 1;
    local cc = col('sc_combo');
    for i = 1, #combos do
        local l = label(combos[i], SMALL_SIZE);
        local w = (l:size());
        if (cx > cx0 and cx + w > right) then
            cx, lines = cx0, lines + 1;
        end
        put(l, cx, base + (lines - 1) * (h + ROW_GAP * s), cc, pass, LABEL);
        cx = cx + w + GAP * s;
    end
    return h * lines + ROW_GAP * s * (lines - 1);
end

local function fin_row(r, pass, x, y)
    local t = glyphs('sc_deco', 'fin');
    local asc, h = metrics(t);
    put(t, x, y + asc, col('sc_fin'), pass, ATLAS);
    return h;
end

---lays out (and in the drawing passes draws) the chain from (x, y).
---@return number height
local function layout(r, pass, x, y, s)
    local y0, gap = y, ROW_GAP * s;
    if (chain == nil) then -- placing it while unlocked
        return header(r, pass, x, y, 'Skillchain!', col('sc_skillchain'));
    end
    y = y + header(r, pass, x, y, chain.chained and 'Skillchain!' or 'Chance!', col(chain.chained and 'sc_skillchain' or 'sc_chance')) + gap;

    local steps = chain.steps or EMPTY;
    for i = math.max(1, #steps - SHOWN + 1), #steps do
        local step = steps[i];
        y = y + ws_row(r, pass, x, y, s, step) + gap;
        if (step.sc ~= nil) then
            y = y + sc_row(r, pass, x + INDENT * s, y, s, step.sc) + gap;
            local bursts = step.bursts or EMPTY;
            for j = 1, #bursts do
                y = y + burst_row(r, pass, x + INDENT * s, y, s, bursts[j]) + gap;
            end
        end
    end

    if (clock <= chain.closes) then
        y = y + next_row(r, pass, x, y, s);
    else
        y = y + fin_row(r, pass, x, y);
    end
    return y - y0;
end

--[[ component ]]--

---the chain on the current target, or else the party's latest; nil once it's
---lingered its time.
local function pick()
    local m = nil;
    local idx = targets.indices();
    if (idx ~= 0) then
        m = sc.mobs[AshitaCore:GetMemoryManager():GetEntity():GetServerId(idx)];
    end
    if (m == nil) then
        for _, rec in pairs(sc.mobs) do
            if (m == nil or rec.since > m.since) then m = rec; end
        end
    end
    if (m ~= nil and clock > m.closes + sc.LINGER) then return nil; end
    return m;
end

function skillchain.update(ctx, dt)
    clock = sc.now();
    sc.tick(clock);
    chain = pick();
    alpha = 1;
    if (chain ~= nil and clock > chain.closes) then
        alpha = math.max(0, math.min(1, (chain.closes + sc.LINGER - clock) / FADE));
    end
end

function skillchain.measure(ctx)
    if (chain == nil and not hud.is_unlocked()) then return 0, 0; end
    return W * ctx.scale, layout(nil, MEASURE, 0, 0, ctx.scale);
end

function skillchain.draw(r, ctx, x, y)
    local w, h = skillchain.measure(ctx);
    if (w == 0) then return 0, 0; end
    local s = ctx.scale;
    r.set_opacity(chain == nil and 0.5 or alpha);
    layout(r, ATLAS, x, y, s);
    layout(r, LABEL, x, y, s);
    r.set_opacity(1);
    return w, h;
end

--[[ commands ]]--

---/cc skillchain demo - plays a made-up chain on the current target: an
---opener, two skillchains and their bursts, then the end.
function skillchain.command(ctx, args)
    if (args[1] == 'demo') then
        local idx = targets.indices();
        sc.play(idx ~= 0 and AshitaCore:GetMemoryManager():GetEntity():GetServerId(idx) or 0);
        return true, 'skillchain: playing a demo chain';
    end
    return false;
end

return skillchain;
