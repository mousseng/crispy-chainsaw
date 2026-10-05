--[[
* the client's zone maps: which map covers a position, and its texture.
*
* ported from boussole (loonsies). the client keeps a table of every map,
* one 14-byte entry per zone floor; an entry gives the map's scale and offset
* and which dat holds its image. which floor a position is on comes from the
* client's own floor check, called through ffi.
*
* map space: world x/y (y is north) scaled into 512 units across the map
* image, y flipped, less the entry's offset. a map image is drawn over 0..512
* in both axes whatever its pixel size.
--]]

local bit  = require('bit');
local ffi   = require('ffi');
local d3d8  = require('d3d8');
local atlas = require('ui.atlas');

local C = ffi.C;
local mem = ashita.memory;

-- from https://discord.com/channels/264673946257850368/445394504040579092/634988737088192512
local MAP_TABLE_SIG = '8A0D????????5333C05684C95774??8A5424188B7424148B7C2410B9';
-- from https://discord.com/channels/264673946257850368/1104281907237245008/1375196315545501756
local FLOOR_FN_SIG  = '8B542408568D4424108BF18B4C2410508B44240C';
local FLOOR_OBJ_SIG = '8B7424148B4424108B7C240C8B0D';
local MAX_ENTRIES   = 3000; -- the table's length isn't known; boussole's generator scans this far
local IMAGE_AT      = 0x41; -- image header offset in a map dat

pcall(ffi.cdef, [[
    #pragma pack(push, 1)
    typedef struct {
        uint16_t zone;
        uint8_t  floor;
        uint8_t  floor_index;
        uint8_t  flags;      // low nibble: dat range; high nibble: key item range
        int8_t   scale;
        int8_t   key_offset;
        uint8_t  unknown;
        uint16_t dat_offset;
        int16_t  offset_x;
        int16_t  offset_y;
    } cc_map_entry_t;

    typedef struct {
        uint32_t size;
        int32_t  width;
        int32_t  height;
        uint16_t planes;
        uint16_t bits;
        uint32_t compression;
        uint32_t image_size;
        uint32_t res_x;
        uint32_t res_y;
        uint32_t used_colors;
        uint32_t important_colors;
        uint32_t type;
    } cc_map_image_t;
    #pragma pack(pop)

    typedef int32_t (__thiscall* cc_floor_fn)(void* self, float x, float y, float z);

    typedef struct {
        void*    base;
        void*    allocation_base;
        uint32_t allocation_protect;
        size_t   size;
        uint32_t state;
        uint32_t protect;
        uint32_t type;
    } cc_mbi_t;
    size_t VirtualQuery(const void* addr, cc_mbi_t* info, size_t len);
]]);
-- separately: these may already be declared by something else in this state.
pcall(ffi.cdef, [[ typedef struct FILE FILE; ]]);
pcall(ffi.cdef, [[
    int fopen_s(FILE** file, const char* name, const char* mode);
    int fclose(FILE* file);
    int fseek(FILE* file, long offset, int origin);
    long ftell(FILE* file);
    size_t fread(void* buffer, size_t size, size_t count, FILE* file);
]]);

local DXT = {
    [0x44585431] = 'D3DFMT_DXT1', [0x44585432] = 'D3DFMT_DXT2', [0x44585433] = 'D3DFMT_DXT3',
    [0x44585434] = 'D3DFMT_DXT4', [0x44585435] = 'D3DFMT_DXT5',
};
local BITMAP = 0x0000000A;

local zonemap = {};

local MEM_COMMIT, PAGE_NOACCESS, PAGE_GUARD = 0x1000, 0x01, 0x100;

local entries = nil;           -- cc_map_entry_t*
local index = nil;             -- zone -> floor -> entry index
local floors = {};             -- zone -> number of floors with a map
local floor_fn, floor_obj = nil, nil;

---set by the caller: fn(fmt, ...) noting each step that calls into the client
---or d3d, so a crash there can be pinned to the last step noted.
zonemap.trace = nil;

local function trace(fmt, ...)
    if (zonemap.trace ~= nil) then zonemap.trace(fmt, ...); end
end

---how many bytes from addr (up to len) are committed, readable memory: reading
---past a mapped region through ffi is an access violation, not an error.
local function readable(addr, len)
    local mbi = ffi.new('cc_mbi_t');
    local at, stop = addr, addr + len;
    while (at < stop) do
        if (C.VirtualQuery(ffi.cast('void*', at), mbi, ffi.sizeof(mbi)) == 0) then break; end
        local p = mbi.protect;
        if (mbi.state ~= MEM_COMMIT or p == 0 or bit.band(p, PAGE_NOACCESS) ~= 0 or bit.band(p, PAGE_GUARD) ~= 0) then break; end
        at = tonumber(ffi.cast('uintptr_t', mbi.base)) + tonumber(mbi.size);
    end
    return math.max(0, math.min(at, stop) - addr);
end

---finds the map table and the floor check, and indexes the table by zone and
---floor. raises if the client doesn't match the signatures.
function zonemap.init()
    if (index ~= nil) then return; end

    trace('init: finding signatures');
    local at = mem.find('FFXiMain.dll', 0, MAP_TABLE_SIG, 0, 0);
    if (at == 0) then error('zonemap: map table signature not found', 0); end
    local ptr = mem.read_uint32(at + 0x1C);
    if (ptr == 0) then error('zonemap: map table is null', 0); end

    local fn = mem.find('FFXiMain.dll', 0, FLOOR_FN_SIG, 0, 0);
    local obj = mem.find('FFXiMain.dll', 0, FLOOR_OBJ_SIG, 0x0E, 0);
    if (fn == 0 or obj == 0) then error('zonemap: floor check signatures not found', 0); end
    floor_fn, floor_obj = ffi.cast('cc_floor_fn', fn), obj;

    local size = ffi.sizeof('cc_map_entry_t');
    local count = math.floor(readable(ptr, (MAX_ENTRIES + 1) * size) / size);
    trace('init: table at 0x%08X, %d readable entries; floor fn 0x%08X, obj at 0x%08X', ptr, count, fn, obj);
    if (count == 0) then error('zonemap: map table isn\'t readable', 0); end
    entries = ffi.cast('cc_map_entry_t*', ptr);
    index = {};
    for i = 0, count - 1 do
        local e = entries[i];
        local zone, floor = e.zone, e.floor;
        if (zone > 0) then
            local z = index[zone];
            if (z == nil) then
                z = {};
                index[zone] = z;
            end
            if (z[floor] == nil) then -- later duplicates are unused copies
                z[floor] = i;
                floors[zone] = (floors[zone] or 0) + 1;
            end
        end
    end
    trace('init: indexed');
end

---the floor the client puts a world position on (Ashita's x, y, z: y north,
---z up), or nil.
local traced_floor = false;

function zonemap.floor_at(x, y, z)
    local self = mem.read_uint32(mem.read_uint32(floor_obj));
    if (self == 0) then return nil; end
    if (not traced_floor) then
        traced_floor = true;
        trace('floor_at: first call, this 0x%08X, (%.1f, %.1f, %.1f)', self, x, y, z);
    end
    -- the client's vectors are x, up, north
    return floor_fn(ffi.cast('void*', self), x, z, y);
end

---whether the zone has more than one mapped floor, i.e. whether entities need
---their floor checked before they're shown.
function zonemap.multi_floor(zone)
    return (floors[zone] or 0) > 1;
end

---the map for a zone floor: { zone, floor, scale, offset_x, offset_y, dat }
---or nil when it has none.
function zonemap.find(zone, floor)
    local z = index[zone];
    local i = z and z[floor];
    if (i == nil) then return nil; end
    local e = entries[i];
    if (e.scale == 0) then return nil; end
    local low, dat = e.flags % 16, nil;
    if (low == 0) then dat = e.dat_offset + 5312;
    elseif (low == 1) then dat = e.dat_offset + 53295;
    elseif (low == 2) then dat = e.dat_offset + 54295;
    else return nil; end
    return {
        zone = zone, floor = floor, dat = dat,
        k = math.abs(e.scale) / 2560 * 512, -- world units -> map units
        offset_x = e.offset_x, offset_y = e.offset_y,
    };
end

---world x, y (y north) -> map units (0..512 across the image).
function zonemap.to_map(m, x, y)
    return x * m.k - m.offset_x, -y * m.k - m.offset_y;
end

--[[ texture ]]--

---reads a whole file through the c runtime's fopen_s, which xipivot redirects.
local function read_file(path)
    local fp = ffi.new('FILE*[1]');
    if (C.fopen_s(fp, path, 'rb') ~= 0 or fp[0] == nil) then
        return nil, 'can\'t open ' .. path;
    end
    local f = fp[0];
    local size = (C.fseek(f, 0, 2) == 0) and C.ftell(f) or -1;
    if (size <= 0 or C.fseek(f, 0, 0) ~= 0) then
        C.fclose(f);
        return nil, 'can\'t size ' .. path;
    end
    local buf = ffi.new('uint8_t[?]', size);
    local got = C.fread(buf, 1, size, f);
    C.fclose(f);
    if (got ~= size) then return nil, 'short read on ' .. path; end
    return buf, size;
end

local function new_texture(w, h, fmt)
    local res, tex = d3d8.get_device():CreateTexture(w, h, 1, 0, fmt, C.D3DPOOL_MANAGED);
    if (res ~= C.S_OK) then return nil, 'CreateTexture failed: ' .. d3d8.get_error(res); end
    local pitch, bits = atlas.lock(tex);
    if (pitch == nil) then
        tex:Release();
        return nil, 'LockRect failed: ' .. d3d8.get_error(bits);
    end
    return tex, pitch, bits;
end

---block-compressed images go to the gpu as they are.
local function load_dxt(buf, size, img, fmt)
    local at = IMAGE_AT + ffi.sizeof('cc_map_image_t') + 8; -- 8 unknown bytes follow the header
    local block = fmt == 'D3DFMT_DXT1' and 8 or 16;
    -- one row of blocks per 4 pixel rows; Pitch is the bytes per row of blocks
    local row, rows = math.ceil(img.width / 4) * block, math.ceil(img.height / 4);
    if (at + row * rows > size) then return nil, 'truncated image'; end
    trace('texture: %s %dx%d, creating', fmt, img.width, img.height);
    local tex, pitch, dst = new_texture(img.width, img.height, C[fmt]);
    if (tex == nil) then return nil, pitch; end
    trace('texture: locked, pitch %d (row %d x %d), bits %s', pitch, row, rows, tostring(dst));
    if (pitch < row or dst == nil) then
        tex:UnlockRect(0);
        tex:Release();
        return nil, ('unexpected lock (pitch %d for rows of %d)'):format(pitch, row);
    end
    for r = 0, rows - 1 do
        ffi.copy(dst + r * pitch, buf + at + r * row, row);
    end
    tex:UnlockRect(0);
    return tex;
end

---uncompressed images: bottom-up rows of 8-bit paletted, 16/24/32-bit pixels.
local function load_bitmap(buf, size, img)
    local w, h, bits = img.width, img.height, img.bits;
    local at = IMAGE_AT + ffi.sizeof('cc_map_image_t');
    local palette = nil;
    if (bits == 8) then
        palette = ffi.cast('uint32_t*', buf + at);
        at = at + 1024;
    elseif (bits ~= 16 and bits ~= 24 and bits ~= 32) then
        return nil, ('unsupported bitmap depth %d'):format(bits);
    end
    local bpp = bits / 8;
    if (at + w * h * bpp > size) then return nil, 'truncated image'; end

    trace('texture: %d-bit bitmap %dx%d, creating', bits, w, h);
    local tex, pitch, dst = new_texture(w, h, C.D3DFMT_A8R8G8B8);
    if (tex == nil) then return nil, pitch; end
    if (pitch < w * 4 or dst == nil) then
        tex:UnlockRect(0);
        tex:Release();
        return nil, ('unexpected lock (pitch %d for rows of %d)'):format(pitch, w * 4);
    end
    local src = buf + at;
    for y = 0, h - 1 do
        local out = ffi.cast('uint32_t*', dst + (h - 1 - y) * pitch);
        local row = src + y * w * bpp;
        for x = 0, w - 1 do
            local p;
            if (bits == 8) then
                p = palette[row[x]];
                p = p >= 0x01000000 and (p % 0x01000000 + 0xFF000000) or p % 0x01000000;
            elseif (bits == 16) then -- rgb565
                local v = row[x * 2] + row[x * 2 + 1] * 256;
                local r, g, b = math.floor(v / 2048) % 32, math.floor(v / 32) % 64, v % 32;
                p = 0xFF000000 + math.floor(r * 255 / 31) * 65536 + math.floor(g * 255 / 63) * 256 + math.floor(b * 255 / 31);
            elseif (bits == 24) then
                local o = x * 3;
                p = 0xFF000000 + row[o + 2] * 65536 + row[o + 1] * 256 + row[o];
            else
                local o = x * 4;
                p = (row[o + 3] > 0 and 0xFF000000 or 0) + row[o + 2] * 65536 + row[o + 1] * 256 + row[o];
            end
            out[x] = p;
        end
    end
    tex:UnlockRect(0);
    return tex;
end

---loads a map's image into a texture, released by the garbage collector once
---nothing (including a frame being drawn) holds it.
---@return ffi.cdata*|nil IDirect3DTexture8
---@return string|nil error
function zonemap.texture(m)
    local path = AshitaCore:GetResourceManager():GetFilePath(m.dat);
    if (path == nil or path == '') then return nil, ('no path for dat %d'):format(m.dat); end
    trace('texture: zone %d floor %d, reading %s', m.zone, m.floor, path);
    local buf, size = read_file(path);
    if (buf == nil) then return nil, size; end
    if (size < IMAGE_AT + ffi.sizeof('cc_map_image_t')) then return nil, 'not a map dat: ' .. path; end

    local img = ffi.cast('cc_map_image_t*', buf + IMAGE_AT);
    if (img.width <= 0 or img.height <= 0 or img.width > 4096 or img.height > 4096) then
        return nil, 'bad image size in ' .. path;
    end
    local tex, err;
    if (DXT[img.type] ~= nil) then
        tex, err = load_dxt(buf, size, img, DXT[img.type]);
    elseif (img.type == BITMAP) then
        tex, err = load_bitmap(buf, size, img);
    else
        return nil, ('unsupported image type 0x%08X in %s'):format(img.type, path);
    end
    if (tex == nil) then return nil, err; end
    trace('texture: done');
    return d3d8.gc_safe_release(tex);
end

return zonemap;
