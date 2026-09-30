addon.name = 'linhud'
addon.author = 'lin'
addon.version = '0.1'
addon.desc = 'performant HUD for ashita'

require('common');
local d3d8     = require('d3d8');
local ffi      = require('ffi');
local settings = require('settings');
local atlas    = require('ui.atlas');
local hud      = require('ui.hud');
local png      = require('ui.png');
local render   = require('ui.render');
local text     = require('ui.text');
local theme    = require('ui.theme');

-- components in paint order (later draws on top).
local COMPONENTS = { 'party', 'demo' };
for _, name in ipairs(COMPONENTS) do
    hud.register(require('components.' .. name));
end

local defaults = T{
    theme      = 'default',
    scale      = 1,
    components = hud.defaults(),
};

local linhud = {
    settings = nil,
};

-- frame cost, averaged over the last second.
pcall(ffi.cdef, [[
    int QueryPerformanceCounter(int64_t* count);
    int QueryPerformanceFrequency(int64_t* freq);
]]);
local qpc = ffi.new('int64_t[1]');
local function ticks()
    ffi.C.QueryPerformanceCounter(qpc);
    return tonumber(qpc[0]);
end
local qpf = ffi.new('int64_t[1]');
ffi.C.QueryPerformanceFrequency(qpf);
local ticks_per_ms = tonumber(qpf[0]) / 1000;
local timing = { total = 0, frames = 0, worst = 0, avg = 0, max = 0, window = ticks(), last = ticks() };

local function msg(fmt, ...)
    print(('\30\81[\30\06linhud\30\81]\30\01 ' .. fmt):format(...));
end

local function user_dir()
    return (AshitaCore:GetInstallPath():gsub('[\\/]+$', '')) .. '/config/addons/linhud';
end

local function apply_theme(name, scale)
    local ok, err = theme.apply(name, scale);
    if (not ok) then
        msg('failed to load theme "%s": %s', name, tostring(err));
        return false;
    end
    text.restyle();
    if (linhud.settings.theme ~= name or linhud.settings.scale ~= scale) then
        linhud.settings.theme, linhud.settings.scale = name, scale;
        settings.save();
    end
    return true;
end

---(re)binds everything to a settings table; runs on load and whenever the
---settings library reloads (e.g. switching characters).
local function use_settings(s)
    linhud.settings = s;
    hud.bind(s);
    local active = theme.active();
    if (active == nil or active.name ~= s.theme or active.scale ~= s.scale) then
        if (not apply_theme(s.theme, s.scale) and theme.active() == nil) then
            apply_theme('default', 1); -- a broken saved theme shouldn't leave us blank
        end
    end
end

hud.on_save = function ()
    settings.save();
end

settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then use_settings(s); end
end);

ashita.events.register('load', 'load_cb', function ()
    theme.paths = {
        user_dir() .. '/themes',
        addon.path:gsub('[\\/]+$', '') .. '/themes',
    };
    use_settings(settings.load(defaults));
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    local t0 = ticks();
    local dt = (t0 - timing.last) / ticks_per_ms / 1000;
    timing.last = t0;

    if (theme.texture() == nil) then
        return;
    end

    local _, vp = d3d8.get_device():GetViewport();
    render.begin_frame();
    if (vp ~= nil) then
        hud.frame(render, dt, vp.Width, vp.Height, text);
    end
    render.end_frame();

    local t1 = ticks();
    local cost = t1 - t0;
    timing.total, timing.frames = timing.total + cost, timing.frames + 1;
    if (cost > timing.worst) then timing.worst = cost; end
    if (t1 - timing.window >= ticks_per_ms * 1000) then
        timing.avg = timing.total / timing.frames / ticks_per_ms;
        timing.max = timing.worst / ticks_per_ms;
        timing.total, timing.frames, timing.worst, timing.window = 0, 0, 0, t1;
    end
end);

ashita.events.register('mouse', 'mouse_cb', function (e)
    hud.mouse(e);
end);

ashita.events.register('unload', 'unload_cb', function ()
    hud.shutdown();
    text.shutdown();
    theme.release();
end);

local function write_quads()
    local path = ('%s/quads.txt'):format(user_dir());
    ashita.fs.create_dir(user_dir());
    local f, ferr = io.open(path, 'w');
    if (f == nil) then
        msg('failed to save: %s', ferr);
        return;
    end

    local sets = theme.extra('glyphs') or {};
    for name, set in pairs(sets) do
        f:write(('glyph set %s: height=%d pad=%d outline=%s\n'):format(name, set.height, set.pad, tostring(set.outline)));
        for b = 32, 126 do
            local gl = set.glyphs[b];
            if (gl ~= nil) then
                local fr = gl.fill and gl.fill.region;
                local orr = gl.outline and gl.outline.region;
                f:write(('  %q adv=%d off=%d fill=%s outline=%s\n'):format(string.char(b), gl.adv, gl.off,
                    fr and ('%d,%d %dx%d'):format(fr.x, fr.y, fr.w, fr.h) or '-',
                    orr and ('%d,%d %dx%d'):format(orr.x, orr.y, orr.w, orr.h) or '-'));
            end
        end
    end

    local verts, n, cmds = render._batch();
    local tex_of = {};
    for i = 1, cmds.n do
        for q = cmds.first[i], cmds.first[i] + cmds.count[i] - 1 do tex_of[q] = i; end
    end
    f:write(('\n%d quads, %d calls (atlas %dx%d)\n'):format(n, cmds.n, theme.active().sheet_w or 0, theme.active().sheet_h or 0));
    for q = 0, n - 1 do
        local a, d = verts[q * 4], verts[q * 4 + 3];
        f:write(('%4d call%d  x %7.1f..%7.1f  y %7.1f..%7.1f  u %.4f..%.4f  v %.4f..%.4f  c %08X\n'):format(
            q, tex_of[q] or 0, a.x + 0.5, d.x + 0.5, a.y + 0.5, d.y + 0.5, a.u, d.u, a.v, d.v, a.color));
    end
    f:close();
    msg('saved %s (%d quads)', path, n);
end

local function write_atlas()
    local tex = theme.texture();
    if (tex == nil) then
        msg('no theme loaded');
        return;
    end
    -- d3dx8 can only save bmp/dds, so encode the png ourselves.
    local img, err = atlas.read(tex);
    if (img == nil) then
        msg('failed to read atlas: %s', err);
        return;
    end
    local path = ('%s/atlas_%s.png'):format(user_dir(), linhud.settings.theme);
    ashita.fs.create_dir(user_dir());
    local f, ferr = io.open(path, 'wb');
    if (f == nil) then
        msg('failed to save: %s', ferr);
        return;
    end
    f:write(png.encode(img.w, img.h, img.px));
    f:close();
    msg('saved %s (%dx%d)', path, img.w, img.h);
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/linhud') then
        return;
    end
    e.blocked = true;
    local s = linhud.settings;

    -- Handle: /linhud theme [name] - Shows or switches the active theme.
    if (#args >= 2 and args[2] == 'theme') then
        if (#args == 2) then
            msg('theme: %s (scale %.2f)', s.theme, s.scale);
        elseif (apply_theme(args[3], s.scale)) then
            msg('theme: %s', args[3]);
        end
        return;
    end

    -- Handle: /linhud scale <n> - Rebuilds the theme at a new ui scale.
    if (#args == 3 and args[2] == 'scale') then
        local n = tonumber(args[3]);
        if (n == nil or n < 0.5 or n > 4) then
            msg('scale must be between 0.5 and 4');
        elseif (apply_theme(s.theme, n)) then
            msg('scale: %.2f', n);
        end
        return;
    end

    -- Handle: /linhud (unlock | lock) - Toggles moving components with the mouse.
    if (#args == 2 and (args[2] == 'unlock' or args[2] == 'lock')) then
        hud.set_unlocked(args[2] == 'unlock');
        msg(args[2] == 'unlock' and 'unlocked: drag components to move them; /linhud lock when done' or 'locked');
        return;
    end

    -- Handle: /linhud list - Lists components and whether they're enabled.
    if (#args == 2 and args[2] == 'list') then
        for _, c in ipairs(hud.list()) do
            msg('%s: %s', c.name, c.enabled and 'on' or 'off');
        end
        return;
    end

    -- Handle: /linhud stats - Shows renderer cost.
    if (#args == 2 and args[2] == 'stats') then
        local st = render.stats();
        msg('%d quads, %d draw calls, cpu %.3f ms avg / %.3f ms worst (last 1s)', st.quads, st.calls, timing.avg, timing.max);
        return;
    end

    -- Handle: /linhud quads - Writes the last frame's quads and glyph metrics to a file.
    if (#args == 2 and args[2] == 'quads') then
        write_quads();
        return;
    end

    -- Handle: /linhud dump - Saves the theme atlas to a png for inspection.
    if (#args == 2 and args[2] == 'dump') then
        write_atlas();
        return;
    end

    -- Handle: /linhud <component> [on | off] - Toggles or sets a component.
    if (#args >= 2 and hud.get(args[2]) ~= nil) then
        local c = hud.get(args[2]);
        local on;
        if (args[3] == 'on') then on = true;
        elseif (args[3] == 'off') then on = false;
        else on = not c.ctx.settings.enabled; end
        hud.set_enabled(args[2], on);
        msg('%s: %s', args[2], on and 'on' or 'off');
        return;
    end

    msg('usage: /linhud <component> [on|off] | list | unlock | lock | theme [name] | scale <n> | stats | quads | dump');
end);
