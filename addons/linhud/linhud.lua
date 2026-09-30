addon.name = 'linhud'
addon.author = 'lin'
addon.version = '0.1'
addon.desc = 'performant HUD for ashita'

require('common');
local ffi    = require('ffi');
local atlas  = require('ui.atlas');
local demo   = require('ui.demo');
local png    = require('ui.png');
local render = require('ui.render');
local theme  = require('ui.theme');

local linhud = {
    theme = 'default',
    scale = 1,
    demo  = false,
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
local timing = { total = 0, frames = 0, avg = 0, window = ticks() };

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
    linhud.theme, linhud.scale = name, scale;
    return true;
end

ashita.events.register('load', 'load_cb', function ()
    theme.paths = {
        user_dir() .. '/themes',
        addon.path:gsub('[\\/]+$', '') .. '/themes',
    };
    apply_theme(linhud.theme, linhud.scale);
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    if (theme.texture() == nil) then
        return;
    end

    local t0 = ticks();
    render.begin_frame();
    if (linhud.demo) then
        demo.draw(render, 200, 200, os.clock());
    end
    render.end_frame();

    local t1 = ticks();
    timing.total, timing.frames = timing.total + (t1 - t0), timing.frames + 1;
    if (t1 - timing.window >= ticks_per_ms * 1000) then
        timing.avg = timing.total / timing.frames / ticks_per_ms;
        timing.total, timing.frames, timing.window = 0, 0, t1;
    end
end);

ashita.events.register('unload', 'unload_cb', function ()
    theme.release();
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1] ~= '/linhud') then
        return;
    end
    e.blocked = true;

    -- Handle: /linhud theme [name] - Shows or switches the active theme.
    if (#args >= 2 and args[2] == 'theme') then
        if (#args == 2) then
            msg('theme: %s (scale %.2f)', linhud.theme, linhud.scale);
        elseif (apply_theme(args[3], linhud.scale)) then
            msg('theme: %s', args[3]);
        end
        return;
    end

    -- Handle: /linhud scale <n> - Rebuilds the theme at a new ui scale.
    if (#args == 3 and args[2] == 'scale') then
        local s = tonumber(args[3]);
        if (s == nil or s < 0.5 or s > 4) then
            msg('scale must be between 0.5 and 4');
        elseif (apply_theme(linhud.theme, s)) then
            msg('scale: %.2f', s);
        end
        return;
    end

    -- Handle: /linhud demo - Toggles the renderer demo.
    if (#args == 2 and args[2] == 'demo') then
        linhud.demo = not linhud.demo;
        msg('demo: %s', linhud.demo and 'on' or 'off');
        return;
    end

    -- Handle: /linhud stats - Shows renderer cost for the last frame.
    if (#args == 2 and args[2] == 'stats') then
        local st = render.stats();
        msg('%d quads, %d draw calls, %.3f ms/frame cpu (1s avg)', st.quads, st.calls, timing.avg);
        return;
    end

    -- Handle: /linhud dump - Saves the theme atlas to a png for inspection.
    if (#args == 2 and args[2] == 'dump') then
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
        local path = ('%s/atlas_%s.png'):format(user_dir(), linhud.theme);
        ashita.fs.create_dir(user_dir());
        local f, ferr = io.open(path, 'wb');
        if (f == nil) then
            msg('failed to save: %s', ferr);
            return;
        end
        f:write(png.encode(img.w, img.h, img.px));
        f:close();
        msg('saved %s (%dx%d)', path, img.w, img.h);
        return;
    end

    msg('usage: /linhud theme [name] | scale <n> | demo | stats | dump');
end);
