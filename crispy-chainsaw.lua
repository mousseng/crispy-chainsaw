addon.name = 'crispy-chainsaw'
addon.author = 'lin'
addon.version = 'unstable'
addon.desc = 'performant HUD for ashita'

require('common');
local d3d8     = require('d3d8');
local ffi      = require('ffi');
local settings = require('settings');
local client   = require('game.client');
local treasure = require('game.treasure');
local jitlog   = require('diag.jitlog');
local mem      = require('diag.mem');
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

local cc = {
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
    print(('\30\81[\30\06crispy-chainsaw\30\81]\30\01 ' .. fmt):format(...));
end

local function user_dir()
    return (AshitaCore:GetInstallPath():gsub('[\\/]+$', '')) .. '/config/addons/crispy-chainsaw';
end

local function apply_theme(name, scale)
    local ok, err = theme.apply(name, scale);
    if (not ok) then
        msg('failed to load theme "%s": %s', name, tostring(err));
        return false;
    end
    text.restyle();
    if (cc.settings.theme ~= name or cc.settings.scale ~= scale) then
        cc.settings.theme, cc.settings.scale = name, scale;
        settings.save();
    end
    return true;
end

---(re)binds everything to a settings table; runs on load and whenever the
---settings library reloads (e.g. switching characters).
local function use_settings(s)
    cc.settings = s;
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
    msg('details in errors.log; /cc %s reload to try again', name);
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
        msg('couldn\'t find the client data for: %s; crispy-chainsaw won\'t hide for those', table.concat(missing, ', '));
    end
end);

local tb = 0; -- when the frame's build ended (see timing)

local function frame(dt)
    mem.frame_begin();
    local k, e = mem.mark();
    local vw, vh = render.viewport();
    local state = client.poll(ui_state);
    mem.add('setup (viewport, client state)', k, e);
    render.begin_frame();
    if (vw ~= nil) then
        hud.frame(render, dt, vw, vh, text, state);
    end
    tb = ticks();
    k, e = mem.mark();
    render.end_frame();
    mem.add('submit (icons, d3d calls)', k, e);
    mem.frame_end();
end

-- ashita calls each event callback on a new coroutine. a new coroutine's stack
-- starts at 45 slots and the frame regrows it twice (~1.2 KB of heap, every
-- frame), so the frame runs on a coroutine of our own that lives across
-- frames: its stack grows once.
local frame_co = nil;

local function frame_loop(dt)
    while (true) do
        frame(dt);
        dt = coroutine.yield();
    end
end

ashita.events.register('d3d_present', 'present_cb', function ()
    local t0 = ticks();
    local dt = (t0 - timing.last) / ticks_per_ms / 1000;
    timing.last = t0;
    mem.event_thread(coroutine.running());

    if (theme.texture() == nil) then
        return;
    end

    local co = frame_co;
    if (co == nil) then
        co = coroutine.create(frame_loop);
        frame_co = co;
    end
    local ok, err = coroutine.resume(co, dt);
    if (not ok) then
        frame_co = nil; -- dead; the next frame starts a new one
        error(debug.traceback(co, tostring(err)), 0);
    end

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
        mem.roll();
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

local function size(bytes)
    if (bytes >= 1024 * 1024) then return ('%.1f MB'):format(bytes / (1024 * 1024)); end
    return ('%.1f KB'):format(bytes / 1024);
end

local function show_mem()
    local l = mem.lua();
    msg('lua heap %s (peak %s in the last 1s), includes ffi.new cdata', size(l.heap * 1024), size(l.peak * 1024));
    if (l.clean > 0) then
        msg('  garbage per frame: %d bytes (%d frames; %d skipped for gc steps, %d for jit activity)', l.alloc, l.clean, l.gc, l.jit);
    else
        msg('  garbage per frame: unknown (%d frames had gc steps, %d jit activity)', l.gc, l.jit);
    end
    if (l.jit > 0) then
        msg('  frames with jit activity: %d bytes each (trace objects, jit log)', l.jit_alloc);
    end
    msg('  between frames: %d bytes per frame (our other events, ashita\'s per-event coroutines)', l.between);
    msg('  present callback ran on %d different coroutines in %d frames', l.threads, l.frames);
    for _, sec in ipairs(mem.sections()) do
        local ev = sec.events > 0 and (', %d trace events'):format(sec.events) or '';
        msg('    %s: %s%s', sec.name, sec.bytes and ('%d bytes'):format(sec.bytes) or '?', ev);
    end
    local total = 0;
    for kind, e in pairs(mem.textures()) do
        msg('  %s: %d texture%s, %s', kind, e.n, e.n == 1 and '' or 's', size(e.bytes));
        total = total + e.bytes;
    end
    local tn, tb = text.mem();
    msg('  text: %d textures, ~%s (replaced ones wait for the gc)', tn, size(tb));
    msg('  textures total ~%s (managed pool: plus a system memory copy each)', size(total + tb));
    local p = mem.process();
    if (p ~= nil) then
        -- wine leaves private bytes at 0
        msg('process (game + all addons): %sworking set %s (peak %s)',
            p.private > 0 and ('private %s, '):format(size(p.private)) or '', size(p.working_set), size(p.peak_working_set));
        msg('  address space %s / %s used', size(p.va_used), size(p.va_total));
    end
end

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
        or ('%s/atlas_%s.png'):format(user_dir(), cc.settings.theme);
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
    if (#args == 0 or (args[1] ~= '/cc' and args[1] ~= '/crispy-chainsaw')) then
        return;
    end
    e.blocked = true;
    local s = cc.settings;

    -- Handle: /cc theme [name] - Shows or switches the active theme.
    if (#args >= 2 and args[2] == 'theme') then
        if (#args == 2) then
            msg('theme: %s (scale %.2f)', s.theme, s.scale);
        elseif (apply_theme(args[3], s.scale)) then
            msg('theme: %s', args[3]);
        end
        return;
    end

    -- Handle: /cc scale <n> - Rebuilds the theme at a new ui scale.
    if (#args == 3 and args[2] == 'scale') then
        local n = tonumber(args[3]);
        if (n == nil or n < 0.5 or n > 4) then
            msg('scale must be between 0.5 and 4');
        elseif (apply_theme(s.theme, n)) then
            msg('scale: %.2f', n);
        end
        return;
    end

    -- Handle: /cc (unlock | lock) - Toggles moving components with the mouse.
    if (#args == 2 and (args[2] == 'unlock' or args[2] == 'lock')) then
        hud.set_unlocked(args[2] == 'unlock');
        return;
    end

    -- Handle: /cc list - Lists components and whether they're enabled.
    if (#args == 2 and args[2] == 'list') then
        for _, c in ipairs(hud.list()) do
            local state = c.failed and ('failed: ' .. c.failed) or (c.enabled and 'on' or 'off');
            msg('%s: %s', c.name, state);
        end
        return;
    end

    -- Handle: /cc hide [condition] [on | off] - Shows or sets which client states hide the hud.
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

    -- Handle: /cc state - Shows the client states the hud hides for, as currently read.
    if (#args == 2 and args[2] == 'state') then
        for _, cond in ipairs(client.CONDITIONS) do
            msg('%s: %s', cond, ui_state[cond] and 'yes' or 'no');
        end
        msg('top menu: "%s"', client.menu_name());
        return;
    end

    -- Handle: /cc stats - Shows renderer cost.
    if (#args == 2 and args[2] == 'stats') then
        local st = render.stats();
        msg('%d quads, %d draw calls, cpu %.3f ms avg / %.3f ms worst (last 1s)', st.quads, st.calls, timing.avg, timing.max);
        msg('  build %.3f ms (update + draw), submit %.3f ms (uploads + d3d calls)', timing.build_avg, timing.submit_avg);
        local total, recent = jitlog.counts();
        msg('  jit aborts: %d total, %s in the last 10s', total, recent and tostring(recent) or '(not 10s yet)');
        local l = mem.lua();
        msg('  lua heap %s, %s bytes garbage per frame', size(l.heap * 1024), l.clean > 0 and ('%d'):format(l.alloc) or '?');
        local icons = package.loaded['ui.icons'];
        if (icons ~= nil) then
            local is = icons.stats('items');
            msg('icons: %d / %d cells used, %d decoded, %d evicted, %d failed', is.used, is.cells, is.decoded, is.evicted, is.failed);
            local ss = icons.stats('status');
            msg('status icons: %d / %d cells used, %d decoded, %d failed', ss.used, ss.cells, ss.decoded, ss.failed);
        end
        return;
    end

    -- Handle: /cc mem prof [frames] - Finds which source lines allocate during frames.
    if ((#args == 3 or #args == 4) and args[2] == 'mem' and args[3] == 'prof') then
        local n = math.max(1, math.min(600, tonumber(args[4] or '') or 60));
        msg('profiling allocations over the next %d frames (it\'ll stutter)...', n);
        mem.profile(n, function (lines)
            local path = ('%s/memprof.txt'):format(user_dir());
            ashita.fs.create_dir(user_dir());
            local f = io.open(path, 'w');
            if (f ~= nil) then
                f:write(('garbage per frame by source line, over %d frames (interpreted)\n\n'):format(n));
                for _, l in ipairs(lines) do f:write(('%8.1f  %s\n'):format(l.bytes, l.where)); end
                f:close();
            end
            local total = 0;
            for _, l in ipairs(lines) do total = total + l.bytes; end
            msg('%.0f bytes per frame; top lines (all in %s):', total, path);
            for i = 1, math.min(8, #lines) do
                msg('  %6.0f  %s', lines[i].bytes, lines[i].where);
            end
        end);
        return;
    end

    -- Handle: /cc mem [gc] - Shows memory use; gc runs a full collection first.
    if ((#args == 2 or (#args == 3 and args[3] == 'gc')) and args[2] == 'mem') then
        if (args[3] == 'gc') then
            local before, after = mem.collect();
            msg('full gc: lua heap %s -> %s', size(before * 1024), size(after * 1024));
        end
        show_mem();
        return;
    end

    -- Handle: /cc jit - Writes which code luajit couldn't compile, and why.
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

    -- Handle: /cc quads - Writes the last frame's quads and glyph metrics to a file.
    if (#args == 2 and args[2] == 'quads') then
        write_quads();
        return;
    end

    -- Handle: /cc dump [icons | status] - Saves the theme atlas (or an icon atlas) to a png for inspection.
    if ((#args == 2 or (#args == 3 and (args[3] == 'icons' or args[3] == 'status'))) and args[2] == 'dump') then
        write_atlas(args[3]);
        return;
    end

    -- Handle: /cc <component> grow <dir> - Sets which way a component grows.
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

    -- Handle: /cc <component> hide [condition] [on | off | default] - Overrides a hide condition for one component.
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
            msg('usage: /cc %s hide <condition> on|off|default', args[2]);
        end
        return;
    end

    -- Handle: /cc <component> reload - Re-requires a component's module (after an error or an edit).
    if (#args == 3 and args[3] == 'reload' and hud.get(args[2]) ~= nil) then
        hud.reload(args[2]);
        msg('%s: reloaded', args[2]);
        return;
    end

    -- Handle: /cc <component> <args...> - Commands a component handles itself (e.g. exp width).
    if (#args >= 3 and args[3] ~= 'on' and args[3] ~= 'off' and hud.get(args[2]) ~= nil) then
        local handled, message = hud.command(args[2], { select(3, unpack(args)) });
        if (handled) then
            if (message ~= nil) then msg('%s', message); end
            return;
        end
    end

    -- Handle: /cc <component> [on | off] - Toggles or sets a component.
    if (#args >= 2 and hud.get(args[2]) ~= nil) then
        local c = hud.get(args[2]);
        local on;
        if (args[3] == 'on') then on = true;
        elseif (args[3] == 'off') then on = false;
        else on = not c.ctx.settings.enabled; end
        hud.set_enabled(args[2], on);
        return;
    end

    msg('usage: /cc <component> [on|off] | <component> grow <dir> | <component> reload | <component> hide [cond] [on|off|default] | hide [cond] [on|off] | state | list | unlock | lock | theme [name] | scale <n> | stats | mem [gc|prof [frames]] | jit | quads | dump [icons|status]');
end);
