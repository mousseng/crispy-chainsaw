--[[
* client ui state the hud hides for, so it doesn't draw over (or during) the
* game's own interface: chat log expanded, map open, loading / zoning, an
* event running, interface hidden.
*
* the signatures are from xitools (credited there to Syllendel and Velyn). each
* leads to a static address baked into the client's code, so they are scanned
* and resolved once here rather than on every check; a frame costs a handful
* of memory reads. a signature that isn't found (a client update) disables
* just that check, and client.missing() names it.
--]]

local client = {};

-- condition names, in the order they're reported.
client.CONDITIONS = { 'loading', 'event', 'interface', 'map', 'chat' };

local read_u8, read_u32, read_string = ashita.memory.read_uint8, ashita.memory.read_uint32, ashita.memory.read_string;

local function find(pattern, offset)
    local addr = ashita.memory.find('FFXiMain.dll', 0, pattern, offset, 0);
    return (addr ~= nil and addr ~= 0) and addr or nil;
end

---resolves a signature to the static address it references (the imm32 at
---the found address), plus add.
local function static(pattern, offset, add)
    local addr = find(pattern, offset);
    if (addr == nil) then return nil; end
    local ptr = read_u32(addr);
    return ptr ~= 0 and ptr + add or nil;
end

-- chat log object (mov ecx, imm32); the byte at +0xF1 is its size, > 2 when expanded.
local chat_size  = static('83EC??B9????????E8????????0FBF4C24??84C0', 0x04, 0xF1);
-- the variable holding the topmost menu (cmp eax, [imm32]).
local menu_top   = static('8B480C85C974??8B510885D274??3B05', 16, 0);
-- a byte that is 1 while an event (cutscene, npc dialogue) runs (mov al, [imm32]).
local event_flag = static('A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3', 1, 0);
-- interface object (mov ecx, imm32); the byte at +0xB4 is 1 while hidden.
local ui_hidden  = static('8B4424046A016A0050B9????????E8????????F6D81BC040C3', 10, 0xB4);

---@return string[] names of checks whose signature wasn't found
function client.missing()
    local out = {};
    if (chat_size == nil)  then out[#out + 1] = 'chat'; end
    if (menu_top == nil)   then out[#out + 1] = 'map'; end
    if (event_flag == nil) then out[#out + 1] = 'event'; end
    if (ui_hidden == nil)  then out[#out + 1] = 'interface'; end
    return out;
end

--[[ menus ]]--

-- menus the map occupies the screen with. names are 16 bytes, space padded
-- after the 'menu' prefix and nul padded at the end.
local MAP_MENUS = { 'map', 'scanlist', 'cnqframe' };

-- raw menu name -> is a map menu. the client has a few hundred menus at most,
-- so this stays small, and each name is only pattern-matched once.
local is_map = {};

local function classify(raw)
    local name = raw:gsub('%z', ''):match('^menu%s+(%S+)') or '';
    for _, m in ipairs(MAP_MENUS) do
        if (name:sub(1, #m) == m) then return true; end
    end
    return false;
end

---the topmost menu's raw name, or nil when no menu is open.
local function top_menu()
    if (menu_top == nil) then return nil; end
    local menu = read_u32(menu_top);
    if (menu == 0) then return nil; end
    local header = read_u32(menu + 4);
    if (header == 0) then return nil; end
    return read_string(header + 0x46, 16);
end

--[[ checks ]]--

function client.loading()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil or player:GetLoginStatus() ~= 2 or player:GetIsZoning() ~= 0) then
        return true;
    end
    return GetPlayerEntity() == nil;
end

function client.chat()
    return chat_size ~= nil and read_u8(chat_size) > 2;
end

function client.map()
    local raw = top_menu();
    if (raw == nil) then return false; end
    local m = is_map[raw];
    if (m == nil) then
        m = classify(raw);
        is_map[raw] = m;
    end
    return m;
end

function client.event()
    return event_flag ~= nil and read_u8(event_flag) == 1;
end

function client.interface()
    return ui_hidden ~= nil and read_u8(ui_hidden) == 1;
end

---fills out[cond] = boolean for every condition. loading short-circuits the
---rest: nothing else means anything mid-zone.
---@param out table reused between calls
---@return table out
function client.poll(out)
    local loading = client.loading();
    out.loading = loading;
    out.event     = not loading and client.event();
    out.interface = not loading and client.interface();
    out.map       = not loading and client.map();
    out.chat      = not loading and client.chat();
    return out;
end

---the topmost menu's name, trimmed, for `/linhud state`.
function client.menu_name()
    local raw = top_menu();
    return raw and raw:gsub('%z', '') or '';
end

return client;
