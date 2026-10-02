--[[
* the player's items, bag by bag, read from client memory.
*
* bags are only re-read after the server changes them: inventory packets mark
* the bag they're about (or every bag) as stale, and stale bags are read again
* once those packets have been quiet for SETTLE seconds. (addons see a packet
* before the client applies it, so reading straight away would read the old
* contents.) refresh() does that and is cheap to call every frame; while
* nothing is stale it does nothing at all.
*
* static item data (names, descriptions, slots, jobs) is read from the
* resource manager the first time it's asked for and kept.
--]]

local bit      = require('bit');
local ok_enc, encoding = pcall(require, 'gdifonts.encoding');

local band, rshift = bit.band, bit.rshift;

local inventory = {};

inventory.NAMES = {
    [0] = 'inventory', [1] = 'mog safe', [2] = 'storage', [3] = 'temporary',
    [4] = 'mog locker', [5] = 'mog satchel', [6] = 'mog sack', [7] = 'mog case',
    [8] = 'wardrobe', [9] = 'mog safe 2', [10] = 'wardrobe 2', [11] = 'wardrobe 3',
    [12] = 'wardrobe 4', [13] = 'wardrobe 5', [14] = 'wardrobe 6', [15] = 'wardrobe 7',
    [16] = 'wardrobe 8',
};

-- bags grouped the way xitools shows them.
inventory.TABS = {
    { name = 'bag',      bags = { 0, 3 } },
    { name = 'satchel',  bags = { 5, 7, 6 } },
    { name = 'wardrobe', bags = { 8, 10, 11, 12, 13, 14, 15, 16 } },
    { name = 'safe',     bags = { 1, 9, 2, 4 } },
};

-- bags that don't count towards their tab's space used: temporary items
-- are always a fixed size and clear on zoning.
inventory.UNCOUNTED = { [3] = true };

-- bags that only hold equipment.
inventory.GEAR_ONLY = { [8] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [15] = true, [16] = true };

local MAX_BAG = 16;
local SETTLE  = 0.15;
local GIL     = 0xFFFF;
local EQUIPPED = 5; -- item_t.Flags while worn

local bags = {};  -- id -> { items = { item... }, max = slots }
local stale = {}; -- id -> true
local stale_at = nil; -- os.clock() of the last packet that made a bag stale

inventory.gil = 0;
inventory.version = 0; -- bumped whenever any bag's contents change

for id = 0, MAX_BAG do
    bags[id] = { items = {}, max = 0 };
    stale[id] = true;
end
stale_at = 0;

--[[ item data ]]--

local info_cache = {};

-- the client's own glyphs (element icons and so on) that aren't shift-jis.
local GLYPHS = {
    ['\x81\x60'] = '~',
    ['\xEF\x1F'] = 'Fire', ['\xEF\x20'] = 'Ice', ['\xEF\x21'] = 'Wind', ['\xEF\x22'] = 'Earth',
    ['\xEF\x23'] = 'Lightning', ['\xEF\x24'] = 'Water', ['\xEF\x25'] = 'Light', ['\xEF\x26'] = 'Dark',
};

---the client's shift-jis text, as utf-8 for display.
local function display(s)
    if (s == nil) then return ''; end
    s = s:gsub('[\x81\xEF].', GLYPHS);
    if (ok_enc) then s = encoding:ShiftJIS_To_UTF8(s); end
    return (s:gsub('\r', ''));
end

local SLOTS = {
    [1] = 'Main', [2] = 'Sub', [4] = 'Range', [8] = 'Ammo', [16] = 'Head', [32] = 'Body',
    [64] = 'Hands', [128] = 'Legs', [256] = 'Feet', [512] = 'Neck', [1024] = 'Waist',
    [2048] = 'L.Ear', [4096] = 'R.Ear', [8192] = 'L.Ring', [16384] = 'R.Ring', [32768] = 'Back',
};
inventory.SLOTS = SLOTS;

-- names for an item's whole slot mask, where it fits more than one slot.
local SLOT_SETS = { [3] = 'Weapon', [6144] = 'Earring', [24576] = 'Ring' };

local SKILLS = {
    [1] = 'Hand-to-Hand', [2] = 'Dagger', [3] = 'Sword', [4] = 'Great Sword', [5] = 'Axe',
    [6] = 'Great Axe', [7] = 'Scythe', [8] = 'Polearm', [9] = 'Katana', [10] = 'Great Katana',
    [11] = 'Club', [12] = 'Staff', [25] = 'Archery', [26] = 'Marksmanship', [27] = 'Throwing',
    [41] = 'Stringed', [42] = 'Wind',
};

local JOBS = {
    'WAR', 'MNK', 'WHM', 'BLM', 'RDM', 'THF', 'PLD', 'DRK', 'BST', 'BRD', 'RNG',
    'SAM', 'NIN', 'DRG', 'SMN', 'BLU', 'COR', 'PUP', 'DNC', 'SCH', 'GEO', 'RUN',
};
local ALL_JOBS = 0x7FFFFE;

local function job_list(mask)
    if (band(mask, ALL_JOBS) == ALL_JOBS) then return 'All Jobs'; end
    local out = {};
    for i, name in ipairs(JOBS) do
        if (band(rshift(mask, i), 1) == 1) then out[#out + 1] = name; end
    end
    return table.concat(out, ' ');
end

local ITEM_WEAPON, ITEM_ARMOR = 4, 5;

---static data for an item id, or nil if the client doesn't know it.
---@return table|nil { name, log_one, log_many, label, desc, stack, type, targets,
---  slots, jobs, level, ilevel, skill, sort, usable, gear, slot_name, job_names }
function inventory.info(id)
    local info = info_cache[id];
    if (info ~= nil) then return info; end
    local res = AshitaCore:GetResourceManager():GetItemById(id);
    if (res == nil) then return nil; end

    info = {
        name     = res.Name[1] or '',            -- as the client spells it; for commands
        log_one  = res.LogNameSingular[1] or '',
        log_many = res.LogNamePlural[1] or '',
        stack    = res.StackSize,
        type     = res.Type,
        targets  = res.Targets,
        slots    = res.Slots,
        jobs     = res.Jobs,
        level    = res.Level,
        ilevel   = res.ItemLevel,
        sort     = res.ResourceId or id,
        usable   = band(rshift(res.Flags, 10), 1) == 1,
        gear     = res.Type == ITEM_WEAPON or res.Type == ITEM_ARMOR,
    };
    info.label = display(info.name);
    info.desc = display(res.Description[1]);
    if (info.gear) then
        info.slot_name = SLOT_SETS[res.Slots] or SLOTS[res.Slots]
            or (res.Slots <= 3 and SKILLS[res.Skill]) or nil;
        info.job_names = job_list(res.Jobs);
    end
    info_cache[id] = info;
    return info;
end

---the order items are listed in: the client's own item order, then id, then
---the bigger stack first.
function inventory.compare(a, b)
    if (a.sort ~= b.sort) then return a.sort < b.sort; end
    if (a.id ~= b.id) then return a.id < b.id; end
    if (a.count ~= b.count) then return a.count > b.count; end
    return a.bag * 100 + a.index < b.bag * 100 + b.index;
end

--[[ bag access ]]--

-- the client's content-access flags (from atom0s, via xitools): which of
-- wardrobes 3-8 the account has unlocked, one bit each from bit 2.
local access_ptr = ashita.memory.find('FFXiMain.dll', 0, 'A1????????8B88B4000000C1E907F6C101E9', 0, 0);

---whether the player can use the bag at all (some are locked behind content
---or account upgrades).
function inventory.has_access(id)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then return false; end
    if (id == 0) then return true; end
    if (id >= 11 and id <= 16) then
        if (access_ptr == nil or access_ptr == 0) then return false; end
        local p = ashita.memory.read_uint32(access_ptr + 1);
        if (p == 0) then return false; end
        local flags = ashita.memory.read_uint32(p);
        if (flags == 0) then return false; end
        local v = ashita.memory.read_uint8(flags + 0xB4);
        return band(rshift(v, id - 9), 1) ~= 0;
    end
    return inv:GetContainerCountMax(id) > 0;
end

--[[ reading ]]--

local function read_bag(inv, id)
    local bag = bags[id];
    local items, n = bag.items, 0;
    -- items are in slots 1..max; slot 0 is gil in the inventory and unused
    -- in every other bag.
    local max = inv:GetContainerCountMax(id);
    bag.max = max;
    for i = 1, math.min(max, 80) do
        local it = inv:GetContainerItem(id, i);
        if (it ~= nil and it.Id ~= 0 and it.Id ~= GIL) then
            local info = inventory.info(it.Id);
            if (info ~= nil) then
                n = n + 1;
                local e = items[n] or {};
                e.id, e.bag, e.index, e.count, e.flags = it.Id, id, it.Index, it.Count, it.Flags;
                e.sort, e.info = info.sort, info;
                e.locked = band(it.Flags, 1) == 1; -- worn, in the bazaar, ...
                e.equipped = it.Flags == EQUIPPED;
                items[n] = e;
            end
        end
    end
    for i = #items, n + 1, -1 do items[i] = nil; end
    table.sort(items, inventory.compare);
end

---marks a bag (or, with nil, every bag) as needing a re-read.
function inventory.mark(id)
    if (id == nil) then
        for b = 0, MAX_BAG do stale[b] = true; end
    elseif (bags[id] ~= nil) then
        stale[id] = true;
    end
    stale_at = os.clock();
end

---re-reads stale bags once packets have settled.
---@return boolean changed
function inventory.refresh()
    if (stale_at == nil or os.clock() - stale_at < SETTLE) then return false; end
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    if (inv == nil) then return false; end
    local gil = inv:GetContainerItem(0, 0);
    if (gil == nil or inv:GetContainerCountMax(0) == 0) then return false; end -- not loaded yet

    inventory.gil = gil.Count;
    for id = 0, MAX_BAG do
        if (stale[id]) then
            read_bag(inv, id);
            stale[id] = nil;
        end
    end
    stale_at = nil;
    inventory.version = inventory.version + 1;
    return true;
end

---@return table { items, max } (items sorted; don't modify)
function inventory.bag(id)
    return bags[id];
end

--[[ packets ]]--

-- packet id -> offset of the bag id, or true for "every bag".
local WATCH = {
    [0x00A] = true,  -- zone in
    [0x01C] = true,  -- bag sizes
    [0x01D] = true,  -- bags finished loading
    [0x01E] = 0x08,  -- item count changed
    [0x01F] = 0x0A,  -- item assigned to a slot
    [0x020] = 0x0E,  -- item details
};

function inventory.packet_in(e)
    local w = WATCH[e.id];
    if (w == nil) then return; end
    if (w == true) then
        inventory.mark(nil);
    else
        inventory.mark(struct.unpack('B', e.data, w + 1));
    end
end

return inventory;
