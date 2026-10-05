--[[
* texture atlas: shelf-packs images into one power-of-two sheet and uploads it.
*
* each region is surrounded by a 1px copy of its own edge pixels ("extrusion")
* so bilinear filtering never samples a neighbour.
--]]

local ffi   = require('ffi');
local image = require('ui.image');

local atlas = {};

local PAD      = 1;    -- extrusion on each side
local MAX_SIZE = 2048;

---tries to shelf-pack sorted items into a w x h sheet. returns positions or nil.
local function try_pack(items, w, h)
    local pos = {};
    local x, y, shelf = 0, 0, 0;
    for _, it in ipairs(items) do
        local iw, ih = it.img.w + PAD * 2, it.img.h + PAD * 2;
        if (iw > w) then return nil; end
        if (x + iw > w) then
            x, y, shelf = 0, y + shelf, 0;
        end
        if (y + ih > h) then return nil; end
        pos[it.name] = { x = x + PAD, y = y + PAD };
        x = x + iw;
        shelf = math.max(shelf, ih);
    end
    return pos;
end

local function extrude(sheet, x, y, w, h)
    local px, sw = sheet.px, sheet.w;
    for row = y, y + h - 1 do
        px[row * sw + x - 1] = px[row * sw + x];
        px[row * sw + x + w] = px[row * sw + x + w - 1];
    end
    local rb = 4 * (w + 2);
    ffi.copy(px + (y - 1) * sw + x - 1, px + y * sw + x - 1, rb);
    ffi.copy(px + (y + h) * sw + x - 1, px + (y + h - 1) * sw + x - 1, rb);
end

---packs { { name =, img = }, ... } into a single image.
---@return table sheet image
---@return table regions name -> { x, y, w, h, u0, v0, u1, v1 } (texture px / uv)
function atlas.pack(items)
    local sorted = {};
    for i, it in ipairs(items) do sorted[i] = it; end
    table.sort(sorted, function (a, b)
        if (a.img.h ~= b.img.h) then return a.img.h > b.img.h; end
        return a.name < b.name;
    end);

    -- grow alternately in width then height until everything fits.
    local w, h, pos = 64, 64, nil;
    while (true) do
        pos = try_pack(sorted, w, h);
        if (pos ~= nil) then break; end
        if (w >= MAX_SIZE and h >= MAX_SIZE) then
            error('atlas: textures do not fit in a 2048x2048 sheet');
        end
        if (w <= h) then w = w * 2; else h = h * 2; end
    end

    local sheet = image.new(w, h);
    local regions = {};
    for _, it in ipairs(sorted) do
        local p, img = pos[it.name], it.img;
        sheet:blit(img, p.x, p.y);
        extrude(sheet, p.x, p.y, img.w, img.h);
        regions[it.name] = {
            x = p.x, y = p.y, w = img.w, h = img.h,
            u0 = p.x / w, v0 = p.y / h,
            u1 = (p.x + img.w) / w, v1 = (p.y + img.h) / h,
        };
    end
    return sheet, regions;
end

--[[ d3d ]]--

---locks a texture's top level, returning its pitch and a pointer to its bits.
---use this, never tex:LockRect: ashita's wrapper returns lock[0], an ffi
---reference into an array that nothing keeps alive, so once the gc frees the
---array (any allocation can trigger it) Pitch and pBits are read from freed
---memory, and the writes they steer are an access violation.
---@return integer|nil pitch bytes per row (per row of blocks for dxt), or nil on failure
---@return ffi.cdata*|integer bits uint8_t*, or the HRESULT on failure
function atlas.lock(tex, rect, flags)
    local out = ffi.new('D3DLOCKED_RECT[1]');
    local res = tex.lpVtbl.LockRect(tex, 0, out, rect, flags or 0);
    if (res ~= ffi.C.S_OK) then return nil, res; end
    local pitch, bits = out[0].Pitch, ffi.cast('uint8_t*', out[0].pBits);
    out = nil; -- (kept until here, so it outlives both reads)
    return pitch, bits;
end

---uploads a packed sheet into a managed-pool A8R8G8B8 texture. managed textures
---survive device resets, so nothing needs rebuilding on alt-tab.
---@return ffi.cdata* IDirect3DTexture8 (caller owns it; call Release)
function atlas.upload(sheet)
    local d3d8 = require('d3d8');
    local C = ffi.C;
    local device = d3d8.get_device();

    local res, tex = device:CreateTexture(sheet.w, sheet.h, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED);
    if (res ~= C.S_OK) then
        error(('atlas: CreateTexture failed: %s'):format(d3d8.get_error(res)));
    end

    local pitch, dst = atlas.lock(tex);
    if (pitch == nil) then
        tex:Release();
        error(('atlas: LockRect failed: %s'):format(d3d8.get_error(dst)));
    end

    local row = sheet.w * 4;
    for y = 0, sheet.h - 1 do
        ffi.copy(dst + y * pitch, sheet.px + y * sheet.w, row);
    end
    tex:UnlockRect(0);
    return tex;
end

---reads an A8R8G8B8 texture back into an image (for debug dumps).
---@return table|nil image
---@return string|nil error
function atlas.read(tex)
    local d3d8 = require('d3d8');
    local C = ffi.C;

    local dres, desc = tex:GetLevelDesc(0);
    if (dres ~= C.S_OK) then
        return nil, d3d8.get_error(dres);
    end
    if (desc.Format ~= C.D3DFMT_A8R8G8B8) then
        return nil, ('unsupported texture format %d'):format(tonumber(desc.Format));
    end
    local pitch, src = atlas.lock(tex, nil, 0x10); -- D3DLOCK_READONLY
    if (pitch == nil) then
        return nil, d3d8.get_error(src);
    end

    local w, h = desc.Width, desc.Height;
    local img = image.new(w, h);
    for y = 0, h - 1 do
        ffi.copy(img.px + y * w, src + y * pitch, w * 4);
    end
    tex:UnlockRect(0);
    return img;
end

---loads an image file (png/tga/bmp/dds/...) into an image via d3dx.
---@return table|nil image
---@return string|nil error
function atlas.load_file(path)
    local d3d8 = require('d3d8');
    local C = ffi.C;
    local device = d3d8.get_device();

    local info = ffi.new('D3DXIMAGE_INFO[1]');
    if (C.D3DXGetImageInfoFromFileA(path, info) ~= C.S_OK) then
        return nil, 'unreadable image';
    end
    local w, h = info[0].Width, info[0].Height;

    -- exact size, no filtering (D3DX_FILTER_NONE = 1) so pixels come through untouched.
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileExA(device, path, w, h, 1, 0, C.D3DFMT_A8R8G8B8,
        C.D3DPOOL_SYSTEMMEM, 1, 1, 0, nil, nil, ptr);
    if (res ~= C.S_OK) then
        return nil, d3d8.get_error(res);
    end

    local tex = ffi.cast('IDirect3DTexture8*', ptr[0]);
    local pitch, src = atlas.lock(tex, nil, 0x10); -- D3DLOCK_READONLY
    if (pitch == nil) then
        tex:Release();
        return nil, d3d8.get_error(src);
    end

    local img = image.new(w, h);
    for y = 0, h - 1 do
        ffi.copy(img.px + y * w, src + y * pitch, w * 4);
    end
    tex:UnlockRect(0);
    tex:Release();
    return img;
end

return atlas;
