--[[
* jit trace log: which code luajit fails to compile, and why.
*
* attached at load, so it sees the traces luajit tries while the hud warms up;
* code that keeps aborting gets blacklisted and is never retried, so attaching
* later would miss it. once warm, traces are rare, so this costs nothing per
* frame. `/linhud jit` writes the summary to a file.
--]]

local jitlog = {};

local ok_util, util = pcall(require, 'jit.util');
local ok_vmdef, vmdef = pcall(require, 'jit.vmdef');
if (not ok_util) then util = nil; end
if (not ok_vmdef) then vmdef = nil; end

local started = {}; -- trace number -> start location
local aborts = {};  -- 'start | abort location | reason' -> count
local stops = {};   -- start location -> compiled trace count
local naborts, nstops = 0, 0;

local function fmtfunc(func, pc)
    if (util == nil) then return '?'; end
    local fi = util.funcinfo(func, pc);
    if (fi.loc) then return fi.loc; end
    if (fi.ffid and vmdef) then return vmdef.ffnames[fi.ffid] or ('ff#' .. fi.ffid); end
    if (fi.addr) then return ('C:%x'):format(fi.addr); end
    return '?';
end

local function fmterr(err, info)
    if (type(err) ~= 'number') then return tostring(err); end
    if (type(info) == 'function') then
        info = fmtfunc(info);
    elseif (type(info) == 'number' and vmdef and vmdef.bcnames) then
        -- NYI bytecodes come as an opcode number
        info = vmdef.bcnames:sub(info * 6 + 1, info * 6 + 6):gsub('%s+$', '');
    end
    local f = vmdef and vmdef.traceerr[err];
    if (f == nil) then return ('error %d (%s)'):format(err, tostring(info)); end
    local okf, s = pcall(string.format, f, info);
    return okf and s or f;
end

local function on_trace(what, tr, func, pc, otr, oex)
    if (what == 'start') then
        started[tr] = fmtfunc(func, pc);
    elseif (what == 'stop') then
        local loc = started[tr] or '?';
        stops[loc] = (stops[loc] or 0) + 1;
        nstops = nstops + 1;
    elseif (what == 'abort') then
        local key = ('%s | at %s | %s'):format(started[tr] or '?', fmtfunc(func, pc), fmterr(otr, oex));
        aborts[key] = (aborts[key] or 0) + 1;
        naborts = naborts + 1;
    end
end

function jitlog.start()
    if (jit == nil or jit.attach == nil) then return false; end
    jit.attach(on_trace, 'trace');
    return true;
end

function jitlog.stop()
    if (jit ~= nil and jit.attach ~= nil) then jit.attach(on_trace); end
end

local function sorted(t)
    local out = {};
    for k, n in pairs(t) do out[#out + 1] = { k = k, n = n }; end
    table.sort(out, function (a, b) return a.n > b.n; end);
    return out;
end

---writes the log to path. returns the abort and compiled trace counts.
function jitlog.write(path)
    local f, err = io.open(path, 'w');
    if (f == nil) then return nil, err; end
    local status = { false };
    if (jit ~= nil) then status = { jit.status() }; end
    f:write(('%s, jit %s, flags:'):format(jit and jit.version or 'no jit', tostring(status[1])));
    for i = 2, #status do f:write(' ', tostring(status[i])); end
    f:write(('\njit.util %s, jit.vmdef %s\n'):format(util and 'ok' or 'missing', vmdef and 'ok' or 'missing'));

    f:write(('\n%d aborts (trace start | abort site | reason), most frequent first:\n'):format(naborts));
    for _, e in ipairs(sorted(aborts)) do f:write(('%5d  %s\n'):format(e.n, e.k)); end

    f:write(('\n%d compiled traces, by start:\n'):format(nstops));
    for _, e in ipairs(sorted(stops)) do f:write(('%5d  %s\n'):format(e.n, e.k)); end
    f:close();
    return naborts, nstops;
end

return jitlog;
