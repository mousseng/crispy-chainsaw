--[[
* icon atlases: the game's 32x32 item and status icons, decoded on demand into
* one texture per kind, so a screenful of them is a single draw call.
*
* each sheet is a fixed grid of cells (32px plus a 1px copy of each icon's own
* edge, so filtering never samples a neighbour), filled as icons are first
* drawn. nothing is ever repacked: a new icon is decoded from the client's
* resource data and written into its cell alone, and d3d re-uploads only the
* rows that changed.
*
* the item sheet evicts: once every cell is taken, the icon drawn least
* recently gives up its cell. it holds more icons than any one view shows
* (all eight wardrobes are 640), so that's rare. the status sheet is
* append-only: it has a cell for every status the client has icons for
* (ids run to 0x3FF, fewer than a thousand of them exist), so it never fills.
*
* icons requested during a frame are written at the end of it, before the
* frame is submitted, at most BUDGET per sheet per frame; the rest come in
* over the next few frames rather than all at once in one long one.
*
* a sheet's texture is made the first time one of its icons is asked for, so
* nothing is spent until something draws icons.
--]]

local ffi = require('ffi');
local bit = require('bit');

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift;
local floor = math.floor;

local icons = {};

local SIZE   = 32;
local CELL   = SIZE + 2;
local SHEET  = 1024;
local COLS   = floor(SHEET / CELL);
local NCELLS = COLS * COLS;
local BUDGET = 96; -- icons decoded per sheet per frame

local frame = 0;

--[[ decoding ]]--

-- one icon, unpacked, before alpha fixes and extrusion.
local tmp = ffi.new('uint32_t[?]', SIZE * SIZE);
local tmp_a = ffi.new('uint8_t[?]', SIZE * SIZE);

local function argb(a, r, g, b)
    return bor(lshift(a, 24), lshift(r, 16), lshift(g, 8), b);
end

---unpacks a 32x32 dib (the client's icon data: a BITMAPINFOHEADER, then the
---palette if any, then bottom-up rows) into tmp / tmp_a.
---@return boolean ok
---@return string|nil error
local function unpack_dib(s)
    local n = #s;
    if (n < 40) then return false, 'too short'; end
    local p = ffi.cast('const uint8_t*', s);
    local function u16(o) return p[o] + p[o + 1] * 256; end
    local function u32(o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216; end
    local function i32(o) local v = u32(o); return v >= 2147483648 and v - 4294967296 or v; end

    local hsize, w, h = u32(0), i32(4), i32(8);
    local bpp, comp, used = u16(14), u32(16), u32(32);
    if (hsize < 40 or hsize > n) then return false, 'bad header'; end
    if (w ~= SIZE or (h ~= SIZE and h ~= -SIZE)) then return false, ('%dx%d, not 32x32'):format(w, h); end
    if (comp ~= 0 and not (comp == 3 and bpp == 32)) then return false, ('compression %d'):format(comp); end
    if (bpp ~= 4 and bpp ~= 8 and bpp ~= 24 and bpp ~= 32) then return false, ('%d bpp'):format(bpp); end

    local pal, data = hsize, hsize;
    if (comp == 3 and hsize == 40) then data = data + 12; end -- bitfield masks; assumed bgra
    if (bpp <= 8) then
        local ncol = used ~= 0 and used or lshift(1, bpp);
        data = pal + ncol * 4;
    end
    local stride = floor((SIZE * bpp + 31) / 32) * 4;
    if (data + stride * SIZE > n) then return false, 'truncated'; end

    for y = 0, SIZE - 1 do
        local row = data + stride * (h > 0 and (SIZE - 1 - y) or y);
        local out = y * SIZE;
        for x = 0, SIZE - 1 do
            local o;
            if (bpp == 8) then
                o = pal + p[row + x] * 4;
            elseif (bpp == 4) then
                local b = p[row + rshift(x, 1)];
                o = pal + (band(x, 1) == 0 and rshift(b, 4) or band(b, 0x0F)) * 4;
            else
                o = row + x * rshift(bpp, 3);
            end
            local a = bpp == 24 and 255 or p[o + 3];
            tmp[out + x] = argb(0, p[o + 2], p[o + 1], p[o]);
            tmp_a[out + x] = a;
        end
    end
    return true;
end

---fixes up alpha in place. the client's icons store it one of three ways:
---  none at all (every pixel 0): black is transparent, everything else opaque
---  (what d3dx's colour key does for the other addons that load these);
---  ps2-style, 0x80 meaning opaque: scaled up to 0..255;
---  ordinary 0..255: kept.
---transparent pixels then take a neighbour's colour, so filtering at the
---icon's edge blends towards the icon rather than towards black.
local function fix_alpha()
    local top = 0;
    for i = 0, SIZE * SIZE - 1 do
        if (tmp_a[i] > top) then top = tmp_a[i]; end
    end
    for i = 0, SIZE * SIZE - 1 do
        local a = tmp_a[i];
        if (top == 0) then
            a = band(tmp[i], 0x00FFFFFF) == 0 and 0 or 255;
        elseif (top <= 0x80) then
            a = a >= 0x80 and 255 or floor(a * 255 / 0x80 + 0.5);
        end
        tmp_a[i] = a;
    end
    for y = 0, SIZE - 1 do
        for x = 0, SIZE - 1 do
            local i = y * SIZE + x;
            local c = band(tmp[i], 0x00FFFFFF);
            if (tmp_a[i] == 0) then
                if (x > 0 and tmp_a[i - 1] > 0) then c = band(tmp[i - 1], 0x00FFFFFF);
                elseif (x < SIZE - 1 and tmp_a[i + 1] > 0) then c = band(tmp[i + 1], 0x00FFFFFF);
                elseif (y > 0 and tmp_a[i - SIZE] > 0) then c = band(tmp[i - SIZE], 0x00FFFFFF);
                elseif (y < SIZE - 1 and tmp_a[i + SIZE] > 0) then c = band(tmp[i + SIZE], 0x00FFFFFF); end
            end
            -- % 2^32: bit ops return signed int32; see render.lua set_vertex
            tmp[i] = bor(lshift(tmp_a[i], 24), c) % 4294967296;
        end
    end
end

---decodes an icon into a CELL x CELL block at dst (stride in pixels): the
---icon at (1, 1), its edge pixels copied once outward. on failure the block
---is cleared.
---@param s string the client's bitmap data (IItem.Bitmap, IStatusIcon.Bitmap)
---@param dst ffi.cdata* uint32_t*
---@return boolean ok
---@return string|nil error
function icons.decode(s, dst, stride)
    local ok, err = unpack_dib(s);
    if (not ok) then
        for y = 0, CELL - 1 do ffi.fill(dst + y * stride, CELL * 4); end
        return false, err;
    end
    fix_alpha();
    for y = 0, SIZE - 1 do
        local row = dst + (y + 1) * stride;
        ffi.copy(row + 1, tmp + y * SIZE, SIZE * 4);
        row[0], row[SIZE + 1] = row[1], row[SIZE];
    end
    ffi.copy(dst, dst + stride, CELL * 4);
    ffi.copy(dst + (SIZE + 1) * stride, dst + SIZE * stride, CELL * 4);
    return true;
end

--[[ sheets ]]--

local function create(name)
    local d3d8 = require('d3d8');
    local C = ffi.C;
    local res, t = d3d8.get_device():CreateTexture(SHEET, SHEET, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED);
    if (res ~= C.S_OK) then
        error(('icons (%s): CreateTexture failed: %s'):format(name, d3d8.get_error(res)));
    end
    local lres, lock = t:LockRect(0, nil, 0);
    if (lres ~= C.S_OK) then
        t:Release();
        error(('icons (%s): LockRect failed: %s'):format(name, d3d8.get_error(lres)));
    end
    for y = 0, SHEET - 1 do
        ffi.fill(ffi.cast('uint8_t*', lock.pBits) + y * lock.Pitch, SHEET * 4);
    end
    t:UnlockRect(0);
    return t;
end

local function cell_uv(cell)
    local x, y = (cell % COLS) * CELL + 1, floor(cell / COLS) * CELL + 1;
    return x / SHEET, y / SHEET, (x + SIZE) / SHEET, (y + SIZE) / SHEET;
end

local Sheet = {};
Sheet.__index = Sheet;

---@param evicts boolean whether a full sheet gives up its least recently drawn cell
local function new_sheet(name, evicts)
    local sh = setmetatable({ name = name, evicts = evicts }, Sheet);
    sh:reset();
    return sh;
end

function Sheet:reset()
    if (self.tex ~= nil) then self.tex:Release(); end
    self.tex = nil;
    self.key_cell  = {}; -- key -> cell (0-based), or false if it can't be decoded
    self.cell_key  = {}; -- cell -> key
    self.cell_used = {}; -- cell -> frame it was last drawn
    self.next_cell = 0;
    -- this frame's new icons: cells and their bitmaps, as parallel arrays.
    self.p_cell, self.p_src, self.npending = {}, {}, 0;
    self.stats = { decoded = 0, evicted = 0, failed = 0 };
    for c = 0, NCELLS - 1 do self.cell_used[c] = -1; end
end

---the least recently drawn cell not drawn this frame, or nil.
function Sheet:evict()
    local best, oldest = nil, frame;
    for cell = 0, NCELLS - 1 do
        local used = self.cell_used[cell];
        if (used < oldest) then best, oldest = cell, used; end
    end
    if (best ~= nil) then
        self.key_cell[self.cell_key[best]] = nil;
        self.stats.evicted = self.stats.evicted + 1;
    end
    return best;
end

---writes this frame's new icons into the sheet: one lock spanning the rows
---they're in.
function Sheet:flush()
    local n = self.npending;
    if (n == 0) then return; end
    local p_cell, p_src, key_cell, cell_key, cell_used = self.p_cell, self.p_src, self.key_cell, self.cell_key, self.cell_used;
    local top, bottom = SHEET, 0;
    for i = 1, n do
        local y = floor(p_cell[i] / COLS) * CELL;
        if (y < top) then top = y; end
        if (y + CELL > bottom) then bottom = y + CELL; end
    end

    local rect = ffi.new('RECT', { 0, top, COLS * CELL, bottom });
    local res, lock = self.tex:LockRect(0, rect, 0);
    if (res == ffi.C.S_OK) then
        local base, pitch = ffi.cast('uint8_t*', lock.pBits), lock.Pitch;
        for i = 1, n do
            local cell = p_cell[i];
            local x, y = (cell % COLS) * CELL, floor(cell / COLS) * CELL - top;
            local dst = ffi.cast('uint32_t*', base + y * pitch) + x;
            local ok = icons.decode(p_src[i], dst, pitch / 4);
            if (ok) then
                self.stats.decoded = self.stats.decoded + 1;
            else
                -- leave the (cleared) cell to whoever's next; the key stays
                -- marked so it isn't tried again.
                key_cell[cell_key[cell]] = false;
                cell_key[cell], cell_used[cell] = nil, -1;
                self.stats.failed = self.stats.failed + 1;
            end
        end
        self.tex:UnlockRect(0);
    else
        -- try again next frame
        for i = 1, n do
            local cell = p_cell[i];
            key_cell[cell_key[cell]] = nil;
            cell_key[cell], cell_used[cell] = nil, -1;
        end
    end
    for i = 1, n do p_src[i] = nil; end
    self.npending = 0;
end

---finds or allocates the cell for key; bitmap() supplies its data when it
---isn't in the sheet yet.
---@return integer|nil cell
function Sheet:lookup(key, bitmap)
    local cell = self.key_cell[key];
    if (cell == false) then return nil; end
    if (cell ~= nil) then
        self.cell_used[cell] = frame;
        return cell;
    end
    if (self.npending >= BUDGET) then return nil; end

    local src = bitmap();
    if (src == nil) then
        self.key_cell[key] = false;
        return nil;
    end
    if (self.tex == nil) then self.tex = create(self.name); end

    -- fresh cells first; once they're gone, one freed by a failed decode,
    -- then (if this sheet evicts) the least recently drawn.
    cell = nil;
    if (self.next_cell < NCELLS) then
        cell = self.next_cell;
        self.next_cell = cell + 1;
    else
        for c = 0, NCELLS - 1 do
            if (self.cell_key[c] == nil) then cell = c; break; end
        end
        if (cell == nil and self.evicts) then cell = self:evict(); end
        if (cell == nil) then return nil; end -- full (or every icon is on screen)
    end

    self.key_cell[key], self.cell_key[cell], self.cell_used[cell] = cell, key, frame;
    local n = self.npending + 1;
    self.npending = n;
    self.p_cell[n], self.p_src[n] = cell, src;
    return cell;
end

function Sheet:draw(r, cell, x, y, size, color)
    local u0, v0, u1, v1 = cell_uv(cell);
    r.image(self.tex, x, y, size, size, color, u0, v0, u1, v1);
end

local sheets = {
    items  = new_sheet('items', true),
    status = new_sheet('status', false),
};

--[[ api ]]--

local resource = nil;

---draws an item's icon at (x, y), size px square. returns false if it isn't
---available (yet: new icons can take a frame or two to arrive).
---@return boolean drawn
function icons.item(r, id, x, y, size, color)
    local sh = sheets.items;
    local cell = sh:lookup(id, function ()
        resource = resource or AshitaCore:GetResourceManager();
        local item = resource:GetItemById(id);
        return item and item.Bitmap or nil;
    end);
    if (cell == nil) then return false; end
    sh:draw(r, cell, x, y, size, color);
    return true;
end

---draws a status effect's icon (by buff id) at (x, y), size px square.
---returns false if it isn't available (yet).
---@return boolean drawn
function icons.status(r, id, x, y, size, color)
    local sh = sheets.status;
    local cell = sh:lookup(id, function ()
        resource = resource or AshitaCore:GetResourceManager();
        local icon = resource:GetStatusIconByIndex(id);
        return icon and icon.Bitmap or nil;
    end);
    if (cell == nil) then return false; end
    sh:draw(r, cell, x, y, size, color);
    return true;
end

---writes the frame's new icons into the sheets. the renderer calls this just
---before submitting each frame.
function icons.end_frame()
    sheets.items:flush();
    sheets.status:flush();
    frame = frame + 1;
end

---@param which string|nil 'items' (default) or 'status'
---@return table { cells, used, decoded, evicted, failed }
function icons.stats(which)
    local sh = sheets[which or 'items'];
    local st = sh.stats;
    st.cells, st.used = NCELLS, math.min(sh.next_cell, NCELLS);
    return st;
end

---a sheet's texture (nil until its first icon), for debug dumps.
---@param which string|nil 'items' (default) or 'status'
function icons.texture(which)
    return sheets[which or 'items'].tex;
end

function icons.release()
    sheets.items:reset();
    sheets.status:reset();
end

require('ui.render').before_submit(icons.end_frame);

return icons;
