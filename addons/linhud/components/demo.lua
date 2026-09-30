--[[
* the renderer demo as a component, so it can be toggled and moved like any
* other: `/linhud demo`, `/linhud unlock`.
--]]

local demo = require('ui.demo');
local text = require('ui.text');

return {
    update = function (ctx, dt)
        ctx.t = (ctx.t or 0) + dt;
    end,

    draw = function (r, ctx, x, y)
        return demo.draw(r, x, y, ctx.t or 0, text);
    end,
};
