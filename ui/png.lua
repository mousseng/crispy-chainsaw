--[[
* minimal png encoder for debug dumps (d3dx8 cannot save png).
*
* writes 8-bit RGBA with stored (uncompressed) deflate blocks, so output is
* larger than a real encoder's but needs no zlib.
--]]

local ffi = require('ffi');
local bit = require('bit');

local band, bor, bxor, rshift, lshift, bnot = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift, bit.bnot;
local char = string.char;

local png = {};

local crc_table = {};
for n = 0, 255 do
    local c = n;
    for _ = 1, 8 do
        c = band(c, 1) ~= 0 and bxor(0xEDB88320, rshift(c, 1)) or rshift(c, 1);
    end
    crc_table[n] = c;
end

local function crc32(s)
    local c = bnot(0);
    for i = 1, #s do
        c = bxor(crc_table[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8));
    end
    return bnot(c);
end

local function u32be(v)
    return char(band(rshift(v, 24), 0xFF), band(rshift(v, 16), 0xFF), band(rshift(v, 8), 0xFF), band(v, 0xFF));
end

local function chunk(kind, data)
    return u32be(#data) .. kind .. data .. u32be(crc32(kind .. data));
end

---@param w integer
---@param h integer
---@param px ffi.cdata* uint32_t ARGB pixels, row-major, w*h
---@return string png file bytes
function png.encode(w, h, px)
    -- raw scanlines: filter byte 0 then RGBA.
    local stride = w * 4 + 1;
    local raw = ffi.new('uint8_t[?]', stride * h);
    for y = 0, h - 1 do
        local o = y * stride;
        raw[o] = 0;
        for x = 0, w - 1 do
            local p = px[y * w + x];
            local q = o + 1 + x * 4;
            raw[q]     = band(rshift(p, 16), 0xFF);
            raw[q + 1] = band(rshift(p, 8), 0xFF);
            raw[q + 2] = band(p, 0xFF);
            raw[q + 3] = band(rshift(p, 24), 0xFF);
        end
    end
    local total = stride * h;

    -- zlib stream of stored deflate blocks (max 65535 bytes each) + adler32.
    local parts = { char(0x78, 0x01) };
    local a, b = 1, 0;
    for i = 0, total - 1 do
        a = (a + raw[i]) % 65521;
        b = (b + a) % 65521;
    end
    local pos = 0;
    repeat
        local n = math.min(65535, total - pos);
        local final = (pos + n >= total) and 1 or 0;
        parts[#parts + 1] = char(final, band(n, 0xFF), rshift(n, 8), band(bnot(n), 0xFF), band(rshift(bnot(n), 8), 0xFF));
        parts[#parts + 1] = ffi.string(raw + pos, n);
        pos = pos + n;
    until pos >= total;
    parts[#parts + 1] = u32be(bor(lshift(b, 16), a));

    return '\137PNG\r\n\26\n'
        .. chunk('IHDR', u32be(w) .. u32be(h) .. char(8, 6, 0, 0, 0))
        .. chunk('IDAT', table.concat(parts))
        .. chunk('IEND', '');
end

return png;
