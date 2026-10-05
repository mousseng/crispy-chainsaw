--[[
* treasure pool drop times, from the server's 0x0D2 packets.
*
* always loaded (linhud.lua feeds it every incoming packet), so the treas
* component can be toggled without losing track of when things dropped.
*
* each 0x0D2 says whether the item is a new drop or one that was already in
* the pool (sent on joining a party or zoning in), and when it entered the
* pool by the server's clock (StartTime). a new drop's five minutes start when
* its packet arrives. an old one's can only be worked out once the server's
* clock is known: two new drops a while apart give its units (LSB counts
* milliseconds since the map server started; retail is unconfirmed), and each
* new drop pins its offset from os.time(). the offset is dropped on zoning, as
* the next zone may be another map server; the units are kept.
*
* items already in the pool when this loads have no packet; the client's own
* DropTime is used for those once it's been seen to match a packet's
* StartTime.
--]]

local treasure = {};

local SLOTS    = 10;
local LIFETIME = 300;     -- seconds an item stays in the pool
local UNITS    = { 1, 60, 1000 }; -- StartTime ticks per second to try
local MIN_SPAN = 20;      -- seconds between two drops before trusting their ratio
local RATIO_TOLERANCE = 0.15;
local OFFSET_TOLERANCE = 3; -- seconds two drops' offsets may disagree by

-- slot -> { id, start, expires } from the latest 0x0D2 for it; expires is
-- nil for old items (worked out from the clock instead).
local recs = {};

local unit = nil;     -- StartTime ticks per second, once known
local offset = nil;   -- os.time() - StartTime / unit, once known
local sample = nil;   -- { start, t }: the last new drop, to measure against
local same_clock = false; -- seen DropTime == StartTime

---a new drop arrived at os.time() t, StartTime start: learn the clock from it.
local function calibrate(start, t)
    if (unit ~= nil) then
        local o = t - start / unit;
        if (offset == nil or math.abs(o - offset) <= OFFSET_TOLERANCE) then
            offset = o;
            sample = { start = start, t = t };
            return;
        end
        unit, offset = nil, nil; -- disagrees: the guess was wrong; start over
    end
    if (sample ~= nil and t - sample.t >= MIN_SPAN and start > sample.start) then
        local ratio = (start - sample.start) / (t - sample.t);
        for _, u in ipairs(UNITS) do
            if (math.abs(ratio - u) <= u * RATIO_TOLERANCE) then
                unit, offset = u, t - start / u;
                break;
            end
        end
    end
    -- several drops at once all share a t; keep the first as the sample
    if (sample == nil or t - sample.t >= MIN_SPAN or unit ~= nil) then
        sample = { start = start, t = t };
    end
end

---when the item in a pool slot runs out, by os.time(), or nil if unknown.
---@param slot number pool slot, 0-9
---@param id number item id in the slot
---@param drop number the client's DropTime for it
---@return number|nil
function treasure.expires(slot, id, drop)
    local r, start = recs[slot], nil;
    if (r ~= nil and r.id == id) then
        if (drop == r.start) then same_clock = true; end
        if (r.expires ~= nil) then return r.expires; end
        start = r.start;
    elseif (same_clock) then
        start = drop;
    end
    if (start == nil or unit == nil or offset == nil) then return nil; end
    return math.floor(start / unit + offset + LIFETIME);
end

---@return string a line for `/linhud treas clock`
function treasure.describe()
    if (unit == nil) then
        return ('clock unknown%s'):format(sample and ' (one drop seen)' or '');
    end
    return ('%d ticks/s, offset %s, DropTime %s'):format(unit,
        offset and ('%.0f'):format(offset) or 'unknown (zoned)',
        same_clock and 'matches' or 'unconfirmed');
end

function treasure.packet_in(e)
    if (e.id == 0x00A) then
        offset, sample = nil, nil; -- zoned: maybe another map server
        return;
    end
    if (e.id ~= 0x0D2) then return; end
    local id    = struct.unpack('H', e.data, 0x10 + 1);
    local slot  = struct.unpack('B', e.data, 0x14 + 1);
    local old   = struct.unpack('B', e.data, 0x15 + 1) ~= 0;
    local start = struct.unpack('I', e.data, 0x18 + 1);
    if (slot >= SLOTS) then return; end
    if (id == 0) then recs[slot] = nil; return; end

    local r = recs[slot];
    if (r ~= nil and r.id == id and r.start == start) then return; end -- resent on zoning
    local t = os.time();
    recs[slot] = { id = id, start = start, expires = (not old) and t + LIFETIME or nil };
    if (not old) then calibrate(start, t); end
end

return treasure;
