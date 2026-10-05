--[[
* zone map: the current floor's map as a translucent overlay, north up, with
* triangles for the player (and party members) showing where they face, and
* dots for the alliance, other players, npcs and enemies.
*
* the map fades from `opacity` to `opacity_moving` while the player moves.
* markers stay opaque so they can still be read. at zoom 1 the whole map
* fills the square; zoomed in, the view follows the player, stopping at the
* map's edges.
*
* everyone outside the party is found by sweeping the entity table a slice
* per frame (SWEEP slots), reading their positions as the sweep passes; a
* full pass takes ~12 frames, which is far quicker than a dot moves a pixel.
* party members are read every frame, so their arrows turn smoothly.
*
* mouse: the wheel grows and shrinks the map around the cursor, easing to the
* new size so it reads as a zoom (settings.size is where it's heading), and dragging
* with the left button moves it, no unlock needed. clicks and the wheel only
* stop at the map while one is shown.
--]]

local bit     = require('bit');
local hud     = require('ui.hud');
local render  = require('ui.render');
local theme   = require('ui.theme');
local zonemap = require('game.zonemap');

local band = bit.band;
local pi = math.pi;

local POLL  = 0.5;  -- seconds between checks of zone and floor
local SWEEP = 192;  -- entity slots examined per frame
local WHEEL = 1.1;  -- size factor per wheel notch
local EASE  = 0.06; -- time constant (s) of the size easing toward settings.size
local HOLD  = 0.25; -- seconds after the player stops before the map fades back up
local FADE  = 0.2;  -- seconds to fade between the two opacities

local SPAWN_PC, SPAWN_MOB = 0x01, 0x10;
local RENDER_VISIBLE, RENDER_HIDDEN = 0x200, 0x4000;

local PARTY_COLORS = { 'map_party1', 'map_party2', 'map_party3', 'map_party4', 'map_party5' };

local map = {}; -- settings defaults: components/list.lua

local cur, tex = nil, nil;         -- the map shown and its texture
local zone, floor = -1, -1;        -- where the player was at the last poll
local failed_at = nil;             -- 'zone_floor' whose map failed to load, so it's reported once
local since_poll = POLL;
local now, last_move, alpha = 0, -HOLD, -1;
local me = { x = 0, y = 0, heading = 0, index = 0 };

-- the party's entity indices (skipped by the sweep), and the alliance's.
local party_idx = {};
local alliance_idx, nalliance = {}, 0;

-- everyone else, in map units, by kind: the lists being drawn and the ones
-- the sweep is filling. swapped when the sweep wraps.
local function new_lists()
    return { pc = { x = {}, y = {}, n = 0 }, npc = { x = {}, y = {}, n = 0 }, mob = { x = {}, y = {}, n = 0 } };
end
local shown, filling = new_lists(), new_lists();
local cursor = 0;
local traced_sweep = nil; -- the zone whose first sweep was noted

local function msg(fmt, ...)
    print(('\30\81[\30\06linhud\30\81]\30\01 map: ' .. fmt):format(...));
end

-- breadcrumbs for crashes in native code (which take the game down before any
-- lua error can be reported): each step is appended and closed at once, so
-- the last line in map.log is the step that was running.
local LOG = (AshitaCore:GetInstallPath():gsub('[\\/]+$', '')) .. '/config/addons/linhud/map.log';
local function trace(fmt, ...)
    local f = io.open(LOG, 'a');
    if (f == nil) then return; end
    f:write(os.date('%H:%M:%S '), fmt:format(...), '\n');
    f:close();
end
zonemap.trace = trace;
local traced_draw = nil; -- the texture last noted being drawn
local drawn = false;      -- whether last frame showed a map, so the mouse is ours

-- the size being shown (logical px) while it eases toward settings.size, and
-- the spot held still meanwhile: screen (pin_x, pin_y) is (pin_u, pin_v) of
-- the way across the map. pin_x is nil when the size wasn't changed by the
-- wheel (e.g. `/linhud map size`), which grows it from its anchor instead.
local size_shown = nil;
local pin_x, pin_y, pin_u, pin_v = nil, 0, 0, 0;

--[[ game state ]]--

local function reset_lists()
    for _, l in pairs(shown) do l.n = 0; end
    for _, l in pairs(filling) do l.n = 0; end
    cursor = 0;
end

local function push(l, x, y)
    local n = l.n + 1;
    l.x[n], l.y[n], l.n = x, y, n;
end

local function visible(ent, i)
    local f = ent:GetRenderFlags0(i);
    return band(f, RENDER_VISIBLE) ~= 0 and band(f, RENDER_HIDDEN) == 0;
end

---party and alliance membership, then which map the player is on.
local function poll(p, ent)
    local z = p:GetMemberZone(0);
    for k in pairs(party_idx) do party_idx[k] = nil; end
    nalliance = 0;
    for i = 0, 17 do
        local idx = p:GetMemberIsActive(i) ~= 0 and p:GetMemberZone(i) == z and p:GetMemberTargetIndex(i) or 0;
        if (idx ~= 0) then
            party_idx[idx] = true;
            if (i >= 6) then
                nalliance = nalliance + 1;
                alliance_idx[nalliance] = idx;
            end
        end
    end

    local f = zonemap.floor_at(ent:GetLocalPositionX(me.index), ent:GetLocalPositionY(me.index), ent:GetLocalPositionZ(me.index));
    if (f == nil or (z == zone and f == floor)) then return; end
    reset_lists(); -- swept in another map's units
    zone, floor = z, f;

    cur, tex = zonemap.find(z, f), nil;
    if (cur == nil) then return; end
    local t, err = zonemap.texture(cur);
    if (t == nil) then
        local key = ('%d_%d'):format(z, f);
        if (failed_at ~= key) then msg('couldn\'t load the map for zone %d floor %d: %s', z, f, err); end
        failed_at, cur = key, nil;
        return;
    end
    tex = t;
end

---examines the next SWEEP entity slots; everyone visible and not in the
---party goes in the lists being filled. those swap in once the sweep wraps.
local function sweep(ent)
    local size = ent:GetEntityMapSize();
    local check_floor = zonemap.multi_floor(zone);
    if (cursor == 0 and traced_sweep ~= zone) then
        traced_sweep = zone;
        trace('sweep: first pass in zone %d, %d slots, floor checks %s', zone, size, tostring(check_floor));
    end
    local last = math.min(cursor + SWEEP, size);
    for i = cursor, last - 1 do
        if (not party_idx[i] and visible(ent, i)) then
            local x, y = ent:GetLocalPositionX(i), ent:GetLocalPositionY(i);
            if (not check_floor or zonemap.floor_at(x, y, ent:GetLocalPositionZ(i)) == floor) then
                local mx, my = zonemap.to_map(cur, x, y);
                local flags = ent:GetSpawnFlags(i);
                if (band(flags, SPAWN_PC) ~= 0) then
                    push(filling.pc, mx, my);
                elseif (band(flags, SPAWN_MOB) ~= 0) then
                    if (ent:GetHPPercent(i) > 0) then push(filling.mob, mx, my); end
                else
                    push(filling.npc, mx, my); -- npcs, and objects (doors, ???s)
                end
            end
        end
    end
    cursor = last;
    if (cursor >= size) then
        cursor = 0;
        shown, filling = filling, shown;
        for _, l in pairs(filling) do l.n = 0; end
    end
end

---eases the shown size toward settings.size.
local function ease(s, dt)
    if (size_shown == nil) then size_shown = s.size; end
    local d = s.size - size_shown;
    if (math.abs(d) < 0.5) then
        size_shown, pin_x = s.size, nil;
    else
        size_shown = size_shown + d * (1 - math.exp(-dt / EASE));
    end
end

function map.update(ctx, dt)
    local s = ctx.settings;
    ease(s, dt);
    local mm = AshitaCore:GetMemoryManager();
    local p, ent = mm:GetParty(), mm:GetEntity();
    if (now == 0) then
        ashita.fs.create_dir((LOG:gsub('/[^/]*$', '')));
        trace('---- map loaded');
    end
    zonemap.init();
    now = now + dt;

    me.index = p:GetMemberTargetIndex(0);
    if (me.index == 0) then return; end

    since_poll = since_poll + dt;
    if (since_poll >= POLL) then
        since_poll = 0;
        poll(p, ent);
    end

    local x, y = ent:GetLocalPositionX(me.index), ent:GetLocalPositionY(me.index);
    local dx, dy = x - me.x, y - me.y;
    if (alpha >= 0 and dx * dx + dy * dy > 1e-4) then last_move = now; end
    me.x, me.y, me.heading = x, y, ent:GetHeading(me.index);

    local target = (now - last_move < HOLD) and s.opacity_moving or s.opacity;
    if (alpha < 0) then
        alpha = target;
    else
        local step = dt / FADE;
        alpha = alpha < target and math.min(target, alpha + step) or math.max(target, alpha - step);
    end

    if (cur ~= nil) then sweep(ent); end
end

--[[ drawing ]]--

-- the view, set by draw for the helpers below: screen = (map - o) * k + origin.
local ox, oy, k, sx0, sy0, box = 0, 0, 1, 0, 0, 0;

---one kind's dots; a loop on its own, so it compiles once.
local function dots(l, color, edge, scale)
    local xs, ys = l.x, l.y;
    for j = 1, l.n do
        local x, y = sx0 + (xs[j] - ox) * k, sy0 + (ys[j] - oy) * k;
        if (x >= sx0 and y >= sy0 and x < sx0 + box and y < sy0 + box) then
            render.sprite('map_dot', x, y, color, scale);
            render.sprite('map_dot_edge', x, y, edge, scale);
        end
    end
end

---a triangle at world (x, y) pointing along the entity's heading.
local function arrow(x, y, heading, color, edge, scale)
    local mx, my = zonemap.to_map(cur, x, y);
    local px, py = sx0 + (mx - ox) * k, sy0 + (my - oy) * k;
    if (px < sx0 or py < sy0 or px >= sx0 + box or py >= sy0 + box) then return; end
    -- heading 0 is east and turns clockwise on the map; the sprite points up
    local a = heading + pi * 0.5;
    render.sprite_rot('map_arrow', px, py, a, color, scale);
    render.sprite_rot('map_arrow_edge', px, py, a, edge, scale);
end

local function alliance_dots(ent, color, edge, scale)
    for j = 1, nalliance do
        local i = alliance_idx[j];
        if (visible(ent, i)) then
            local mx, my = zonemap.to_map(cur, ent:GetLocalPositionX(i), ent:GetLocalPositionY(i));
            local x, y = sx0 + (mx - ox) * k, sy0 + (my - oy) * k;
            if (x >= sx0 and y >= sy0 and x < sx0 + box and y < sy0 + box) then
                render.sprite('map_dot', x, y, color, scale);
                render.sprite('map_dot_edge', x, y, edge, scale);
            end
        end
    end
end

local function party_arrows(p, ent, edge, scale)
    for i = 1, 5 do
        local idx = p:GetMemberIsActive(i) ~= 0 and p:GetMemberZone(i) == zone and p:GetMemberTargetIndex(i) or 0;
        if (idx ~= 0 and visible(ent, idx)) then
            arrow(ent:GetLocalPositionX(idx), ent:GetLocalPositionY(idx), ent:GetHeading(idx), theme.color(PARTY_COLORS[i]), edge, scale);
        end
    end
end

local function box_size(ctx)
    return math.floor((size_shown or ctx.settings.size) * ctx.scale + 0.5);
end

function map.measure(ctx)
    local b = box_size(ctx);
    if (pin_x == nil) then return b, b; end
    return b, b, pin_x - pin_u * b, pin_y - pin_v * b;
end

function map.draw(r, ctx, x, y)
    local s = ctx.settings;
    box = box_size(ctx);
    drawn = cur ~= nil and tex ~= nil and me.index ~= 0;
    if (not drawn) then return box, box; end

    -- the view: the whole map at zoom 1, else a window on it around the
    -- player, kept inside the map
    local span = 512 / math.max(1, s.zoom);
    local pmx, pmy = zonemap.to_map(cur, me.x, me.y);
    ox = math.max(0, math.min(512 - span, pmx - span * 0.5));
    oy = math.max(0, math.min(512 - span, pmy - span * 0.5));
    k, sx0, sy0 = box / span, x, y;

    if (traced_draw ~= tex) then
        traced_draw = tex;
        trace('draw: recording zone %d floor %d at %.0f,%.0f size %d', cur.zone, cur.floor, x, y, box);
    end
    r.set_opacity(alpha);
    r.image(tex, x, y, box, box, 0xFFFFFFFF, ox / 512, oy / 512, (ox + span) / 512, (oy + span) / 512);
    r.set_opacity(1);

    local mm = AshitaCore:GetMemoryManager();
    local p, ent = mm:GetParty(), mm:GetEntity();
    local edge, scale = theme.color('map_edge'), s.marker;
    dots(shown.npc, theme.color('map_npc'), edge, scale);
    dots(shown.pc, theme.color('map_pc'), edge, scale);
    dots(shown.mob, theme.color('map_mob'), edge, scale);
    alliance_dots(ent, theme.color('map_alliance'), edge, scale);
    party_arrows(p, ent, edge, scale);
    arrow(me.x, me.y, me.heading, theme.color('map_self'), edge, scale * 1.15);
    return box, box;
end

--[[ mouse ]]--

local LIMITS = {
    size   = { 128, 2048, '%d' },
    zoom   = { 1, 8, '%.2f' },
    marker = { 0.5, 4, '%.2f' },
};

---grows or shrinks the map by a wheel notch, keeping the spot under the
---cursor (mx, my, relative to the map) where it is. it may outgrow the
---screen; drag it to see the rest.
local function resize(ctx, mx, my, up)
    local s = ctx.settings;
    local n = math.floor(s.size * (up and WHEEL or 1 / WHEEL) + 0.5);
    n = math.max(LIMITS.size[1], math.min(LIMITS.size[2], n));
    if (n == s.size or ctx.w <= 0) then return; end
    -- held relative to the frame on screen, which may be mid-ease
    pin_x, pin_y, pin_u, pin_v = ctx.x + mx, ctx.y + my, mx / ctx.w, my / ctx.h;
    s.size = n;
    local new = math.floor(n * ctx.scale + 0.5);
    hud.move(ctx.name, pin_x - pin_u * new, pin_y - pin_v * new, new, new);
end

function map.mouse(ctx, ev, mx, my, e)
    if (not drawn) then return false; end
    if (ev == 'wheel') then
        resize(ctx, mx, my, e.delta > 0);
        return true;
    end
    if (ev == 'ldown') then
        pin_x = nil; -- the drag places it now; any easing left grows it from its anchor
        return 'drag';
    end
    return false;
end

--[[ commands ]]--

local function describe(s)
    return ('map size %d, zoom %.2f, marker %.2f, opacity %.2f (moving %.2f)'):format(s.size, s.zoom, s.marker, s.opacity, s.opacity_moving);
end

function map.command(ctx, args)
    local s = ctx.settings;
    local lim = LIMITS[args[1]];
    if (lim ~= nil) then
        if (args[2] ~= nil) then
            local n = tonumber(args[2]);
            if (n == nil or n < lim[1] or n > lim[2]) then
                return true, ('%s must be %s to %s'):format(args[1], tostring(lim[1]), tostring(lim[2]));
            end
            s[args[1]] = args[1] == 'size' and math.floor(n) or n;
        end
        return true, ('map %s: ' .. lim[3]):format(args[1], s[args[1]]);
    end
    if (args[1] == 'opacity') then
        if (args[2] ~= nil) then
            local still, moving = tonumber(args[2]), tonumber(args[3] or s.opacity_moving);
            if (still == nil or moving == nil or still < 0 or still > 1 or moving < 0 or moving > 1) then
                return true, 'usage: /linhud map opacity <still 0..1> [moving 0..1]';
            end
            s.opacity, s.opacity_moving = still, moving;
        end
        return true, ('map opacity %.2f, moving %.2f'):format(s.opacity, s.opacity_moving);
    end
    if (args[1] == 'info') then
        return true, describe(s) .. (cur and (', zone %d floor %d'):format(cur.zone, cur.floor) or ', no map here');
    end
    return false;
end

return map;
