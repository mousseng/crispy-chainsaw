addon.name = 'linhud'
addon.author = 'lin'
addon.version = '0.1'
addon.desc = 'performant HUD for ashita'

require('common');
local atlas = require('ui.atlas');
local png   = require('ui.png');
local theme = require('ui.theme');

local linhud = {
    theme = 'default',
    scale = 1,
};

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

    msg('usage: /linhud theme [name] | scale <n> | dump');
end);
