addon.name = 'linhud'
addon.author = 'lin'
addon.version = '0.1'
addon.desc = 'performant HUD for ashita'

require('common');
local d3d8     = require('d3d8');
local ffi      = require('ffi');
local settings = require('settings');
local client   = require('game.client');
local treasure = require('game.treasure');
local jitlog   = require('diag.jitlog');
local atlas    = require('ui.atlas');
local hud      = require('ui.hud');
local png      = require('ui.png');
local render   = require('ui.render');
local text     = require('ui.text');
local theme    = require('ui.theme');

-- before anything gets hot, so no trace attempt is missed (see diag/jitlog.lua).
jitlog.start();

-- components are required lazily, when first enabled (see ui/hud.lua).
for _, c in ipairs(require('components.list')) do
    hud.register(c.name, c.defaults);
end

local defaults = T{
    theme      = 'default',
    scale      = 1,
    -- client states that hide the hud (see game/client.lua); components can
    -- override each one in their own `hide` table.
    hide       = T{ loading = true, event = true, interface = true, map = true, chat = true },
    fade_in    = 0.15, -- seconds to fade in when toggled on or once nothing hides it; 0 = pop in
    fade_out   = 0.15, -- seconds to fade out when toggled off; 0 = vanish at once
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
-- build: components' update and draw (lua, filling the vertex array);
-- submit: render.end_frame (icon uploads and the d3d calls).
local timing = {
    total = 0, frames = 0, worst = 0, avg = 0, max = 0, window = ticks(), last = ticks(),
    build = 0, submit = 0, build_avg = 0, submit_avg = 0,
};
local ui_state = {}; -- client.poll output, reused every frame

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

---a component failed and has been shut off: say so in chat, and keep the
---full traceback in errors.log where it doesn't flood the chat log.
hud.on_error = function (name, what, err, trace)
    msg('\30\68%s failed (%s) and was turned off:\30\01 %s', name, what, err);
    msg('details in errors.log; /linhud %s reload to try again', name);
    ashita.fs.create_dir(user_dir());
    local f = io.open(user_dir() .. '/errors.log', 'a');
    if (f ~= nil) then
        f:write(('[%s] %s %s\n%s\n\n'):format(os.date('%Y-%m-%d %H:%M:%S'), name, what, trace));
        f:close();
    end
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
    local missing = client.missing();
    if (#missing > 0) then
        msg('couldn\'t find the client data for: %s; linhud won\'t hide for those', table.concat(missing, ', '));
    end
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
        hud.frame(render, dt, vp.Width, vp.Height, text, client.poll(ui_state));
    end
    local tb = ticks();
    render.end_frame();

    local t1 = ticks();
    local cost = t1 - t0;
    timing.total, timing.frames = timing.total + cost, timing.frames + 1;
    timing.build, timing.submit = timing.build + (tb - t0), timing.submit + (t1 - tb);
    if (cost > timing.worst) then timing.worst = cost; end
    if (t1 - timing.window >= ticks_per_ms * 1000) then
        local per = timing.frames * ticks_per_ms;
        timing.avg, timing.build_avg, timing.submit_avg = timing.total / per, timing.build / per, timing.submit / per;
        timing.max = timing.worst / ticks_per_ms;
        timing.total, timing.frames, timing.worst, timing.window = 0, 0, 0, t1;
        timing.build, timing.submit = 0, 0;
    end
end);

ashita.events.register('mouse', 'mouse_cb', function (e)
    hud.mouse(e);
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    treasure.packet_in(e); -- even while treas is off, so drop times survive toggling it
    hud.packet_in(e);
end);

ashita.events.register('unload', 'unload_cb', function ()
    jitlog.stop();
    hud.shutdown();
    if (package.loaded['ui.icons'] ~= nil) then package.loaded['ui.icons'].release(); end
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

local function write_atlas(which)
    local icons = package.loaded['ui.icons'];
    local tex = theme.texture();
    local sheet = which == 'icons' and 'items' or which;
    if (sheet ~= nil) then
        tex = icons and icons.texture(sheet);
        if (tex == nil) then
            msg('no icons loaded yet');
            return;
        end
    elseif (tex == nil) then
        msg('no theme loaded');
        return;
    end
    -- d3dx8 can only save bmp/dds, so encode the png ourselves.
    local img, err = atlas.read(tex);
    if (img == nil) then
        msg('failed to read atlas: %s', err);
        return;
    end
    local path = which ~= nil and ('%s/atlas_%s.png'):format(user_dir(), which)
        or ('%s/atlas_%s.png'):format(user_dir(), linhud.settings.theme);
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
        return;
    end

    -- Handle: /linhud list - Lists components and whether they're enabled.
    if (#args == 2 and args[2] == 'list') then
        for _, c in ipairs(hud.list()) do
            local state = c.failed and ('failed: ' .. c.failed) or (c.enabled and 'on' or 'off');
            msg('%s: %s', c.name, state);
        end
        return;
    end

    -- Handle: /linhud hide [condition] [on | off] - Shows or sets which client states hide the hud.
    if (#args >= 2 and args[2] == 'hide') then
        if (#args == 2) then
            for _, cond in ipairs(client.CONDITIONS) do
                msg('hide during %s: %s', cond, s.hide[cond] and 'on' or 'off');
            end
        elseif (not table.contains(client.CONDITIONS, args[3])) then
            msg('condition must be one of: %s', table.concat(client.CONDITIONS, ', '));
        else
            local on = args[4] == 'on' or (args[4] ~= 'off' and not s.hide[args[3]]);
            hud.set_hide(nil, args[3], on);
            msg('hide during %s: %s', args[3], on and 'on' or 'off');
        end
        return;
    end

    -- Handle: /linhud state - Shows the client states the hud hides for, as currently read.
    if (#args == 2 and args[2] == 'state') then
        for _, cond in ipairs(client.CONDITIONS) do
            msg('%s: %s', cond, ui_state[cond] and 'yes' or 'no');
        end
        msg('top menu: "%s"', client.menu_name());
        return;
    end

    -- Handle: /linhud stats - Shows renderer cost.
    if (#args == 2 and args[2] == 'stats') then
        local st = render.stats();
        msg('%d quads, %d draw calls, cpu %.3f ms avg / %.3f ms worst (last 1s)', st.quads, st.calls, timing.avg, timing.max);
        msg('  build %.3f ms (update + draw), submit %.3f ms (uploads + d3d calls)', timing.build_avg, timing.submit_avg);
        local total, recent = jitlog.counts();
        msg('  jit aborts: %d total, %s in the last 10s', total, recent and tostring(recent) or '(not 10s yet)');
        local icons = package.loaded['ui.icons'];
        if (icons ~= nil) then
            local is = icons.stats('items');
            msg('icons: %d / %d cells used, %d decoded, %d evicted, %d failed', is.used, is.cells, is.decoded, is.evicted, is.failed);
            local ss = icons.stats('status');
            msg('status icons: %d / %d cells used, %d decoded, %d failed', ss.used, ss.cells, ss.decoded, ss.failed);
        end
        return;
    end

    -- Handle: /linhud jit - Writes which code luajit couldn't compile, and why.
    if (#args == 2 and args[2] == 'jit') then
        local path = ('%s/jit.txt'):format(user_dir());
        ashita.fs.create_dir(user_dir());
        local aborts, traces = jitlog.write(path);
        if (aborts == nil) then
            msg('failed to save: %s', traces);
        else
            msg('saved %s (%d aborts, %d compiled traces)', path, aborts, traces);
        end
        return;
    end

    -- Handle: /linhud quads - Writes the last frame's quads and glyph metrics to a file.
    if (#args == 2 and args[2] == 'quads') then
        write_quads();
        return;
    end

    -- Handle: /linhud dump [icons | status] - Saves the theme atlas (or an icon atlas) to a png for inspection.
    if ((#args == 2 or (#args == 3 and (args[3] == 'icons' or args[3] == 'status'))) and args[2] == 'dump') then
        write_atlas(args[3]);
        return;
    end

    -- Handle: /linhud <component> grow <dir> - Sets which way a component grows.
    if (#args >= 3 and args[3] == 'grow' and hud.get(args[2]) ~= nil) then
        local cs = hud.get(args[2]).ctx.settings;
        if (#args == 3) then
            msg('%s grows x: %s, y: %s', args[2], cs.grow_x, cs.grow_y);
        elseif (hud.set_grow(args[2], args[4])) then
            msg('%s grows x: %s, y: %s', args[2], cs.grow_x, cs.grow_y);
        else
            msg('grow must be up, down, left, right, vcenter, hcenter or auto');
        end
        return;
    end

    -- Handle: /linhud <component> hide [condition] [on | off | default] - Overrides a hide condition for one component.
    if (#args >= 3 and args[3] == 'hide' and hud.get(args[2]) ~= nil) then
        local own = hud.get(args[2]).ctx.settings.hide or {};
        local function describe(cond)
            local v = own[cond];
            if (v == nil) then return ('default (%s)'):format(s.hide[cond] and 'on' or 'off'); end
            return v and 'on' or 'off';
        end
        if (#args == 3) then
            for _, cond in ipairs(client.CONDITIONS) do
                msg('%s hides during %s: %s', args[2], cond, describe(cond));
            end
        elseif (not table.contains(client.CONDITIONS, args[4])) then
            msg('condition must be one of: %s', table.concat(client.CONDITIONS, ', '));
        elseif (#args == 4) then
            msg('%s hides during %s: %s', args[2], args[4], describe(args[4]));
        elseif (args[5] == 'on' or args[5] == 'off' or args[5] == 'default') then
            local on = nil;
            if (args[5] ~= 'default') then on = args[5] == 'on'; end
            hud.set_hide(args[2], args[4], on);
            msg('%s hides during %s: %s', args[2], args[4], describe(args[4]));
        else
            msg('usage: /linhud %s hide <condition> on|off|default', args[2]);
        end
        return;
    end

    -- Handle: /linhud <component> reload - Re-requires a component's module (after an error or an edit).
    if (#args == 3 and args[3] == 'reload' and hud.get(args[2]) ~= nil) then
        hud.reload(args[2]);
        msg('%s: reloaded', args[2]);
        return;
    end

    -- Handle: /linhud <component> <args...> - Commands a component handles itself (e.g. exp width).
    if (#args >= 3 and args[3] ~= 'on' and args[3] ~= 'off' and hud.get(args[2]) ~= nil) then
        local handled, message = hud.command(args[2], { select(3, unpack(args)) });
        if (handled) then
            if (message ~= nil) then msg('%s', message); end
            return;
        end
    end

    -- Handle: /linhud <component> [on | off] - Toggles or sets a component.
    if (#args >= 2 and hud.get(args[2]) ~= nil) then
        local c = hud.get(args[2]);
        local on;
        if (args[3] == 'on') then on = true;
        elseif (args[3] == 'off') then on = false;
        else on = not c.ctx.settings.enabled; end
        hud.set_enabled(args[2], on);
        return;
    end

    msg('usage: /linhud <component> [on|off] | <component> grow <dir> | <component> reload | <component> hide [cond] [on|off|default] | hide [cond] [on|off] | state | list | unlock | lock | theme [name] | scale <n> | stats | quads | dump [icons|status]');
end);
