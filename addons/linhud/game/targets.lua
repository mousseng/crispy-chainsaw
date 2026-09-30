--[[
* current target and subtarget, shared by components.
*
* the client keeps targets as a stack: while a subtarget is being picked
* (<st>, <stpc>, ...) the subtarget sits in slot 0 and the main target moves to
* slot 1. read through here so nothing has to remember that.
--]]

local bit = require('bit');

local targets = {};

local LOCKED = 0x01; -- ITarget:GetLockedOnFlags(): locked on to the main target

---@return integer main target entity index (0 = none)
---@return integer subtarget entity index (0 = none)
function targets.indices()
    local t = AshitaCore:GetMemoryManager():GetTarget();
    if (t == nil) then return 0, 0; end
    if (t:GetIsSubTargetActive() ~= 0) then
        return t:GetTargetIndex(1), t:GetTargetIndex(0);
    end
    return t:GetIsActive(0) ~= 0 and t:GetTargetIndex(0) or 0, 0;
end

---@return boolean
function targets.locked()
    local t = AshitaCore:GetMemoryManager():GetTarget();
    return t ~= nil and bit.band(t:GetLockedOnFlags(), LOCKED) ~= 0;
end

return targets;
