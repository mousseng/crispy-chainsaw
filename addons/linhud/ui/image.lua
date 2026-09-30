--[[
* CPU-side ARGB image buffer.
*
* every texture source (generators, files) produces one of these; the atlas
* packer composes them into a single buffer before uploading to the gpu.
* pure lua/ffi with no d3d dependency, so it can be exercised outside the game.
--]]

local ffi = require('ffi');
local bit = require('bit');

local image = {};
image.__index = image;

---@param w integer
---@param h integer
---@return table
function image.new(w, h)
    local self = setmetatable({}, image);
    self.w = w;
    self.h = h;
    self.px = ffi.new('uint32_t[?]', math.max(1, w * h));
    for i = 0, w * h - 1 do -- transparent white; see set_alpha
        self.px[i] = 0x00FFFFFF;
    end
    return self;
end

---@param x integer
---@param y integer
---@param argb integer
function image:set(x, y, argb)
    self.px[y * self.w + x] = argb;
end

---@return integer
function image:get(x, y)
    return self.px[y * self.w + x];
end

---sets a white pixel with the given coverage (0..1). default theme art is
---white-on-alpha so it can be tinted per draw via vertex colour. transparent
---pixels stay white too, or bilinear filtering blends edges toward black.
function image:set_alpha(x, y, a)
    if (a < 0) then a = 0; end
    if (a > 1) then a = 1; end
    self.px[y * self.w + x] = bit.bor(bit.lshift(math.floor(a * 255 + 0.5), 24), 0x00FFFFFF);
end

---copies src into this image at (dx, dy). no blending.
function image:blit(src, dx, dy)
    local sw = src.w;
    for y = 0, src.h - 1 do
        ffi.copy(self.px + (dy + y) * self.w + dx, src.px + y * sw, sw * 4);
    end
end

---returns a copy of the w x h region at (x, y).
function image:sub(x, y, w, h)
    local out = image.new(w, h);
    for row = 0, h - 1 do
        ffi.copy(out.px + row * w, self.px + (y + row) * self.w + x, w * 4);
    end
    return out;
end

---fills every pixel by evaluating fn(px, py) -> coverage at pixel centres.
function image:fill(fn)
    for y = 0, self.h - 1 do
        for x = 0, self.w - 1 do
            self:set_alpha(x, y, fn(x + 0.5, y + 0.5));
        end
    end
    return self;
end

return image;
