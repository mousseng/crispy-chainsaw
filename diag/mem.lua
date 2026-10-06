--[[
* memory use: the lua heap, garbage made per frame, the textures we own, and
* the process as a whole.
*
* the lua heap (collectgarbage('count')) includes everything ffi.new makes,
* since cdata lives on it. what it can't see is memory behind a pointer: d3d
* textures, gdifonts' textures, the c runtime. textures are sized here as
* they're created instead. ones freed through ffi.gc (gc_safe_release) only go
* when the gc collects the small cdata holding them, and the gc doesn't know
* how big they are, so they can pile up; `/cc mem gc` shows how many were.
*
* per-frame garbage is the heap's growth across hud.frame and end_frame. the
* gc can't be paused to measure it (restart would re-arm it every frame), so
* frames where it ran a step and the heap shrank are left out; for a frame
* that allocates nothing, the reading is exact. sections (mem.mark/mem.add)
* split it up the same way: per component, setup, submit.
*
* the jit allocates as well: trace objects while it compiles, and the jit
* log's callback (funcinfo tables, strings) on every trace event. that lands
* in whichever section was running, so frames and sections with trace events
* are counted apart from the rest.
--]]

local ffi = require('ffi');
local jitlog = require('diag.jitlog');
local events = jitlog.events;

local mem = {};

pcall(ffi.cdef, [[
    typedef struct {
        uint32_t cb;
        uint32_t page_faults;
        size_t   peak_working_set;
        size_t   working_set;
        size_t   quota_peak_paged;
        size_t   quota_paged;
        size_t   quota_peak_nonpaged;
        size_t   quota_nonpaged;
        size_t   pagefile;
        size_t   peak_pagefile;
        size_t   private_bytes;
    } cc_pmc_t;
    typedef struct {
        uint32_t length;
        uint32_t load;
        uint64_t total_phys;
        uint64_t avail_phys;
        uint64_t total_pagefile;
        uint64_t avail_pagefile;
        uint64_t total_virtual;
        uint64_t avail_virtual;
        uint64_t avail_extended_virtual;
    } cc_memstatus_t;
]]);
-- separately: these may already be declared by something else in this state.
pcall(ffi.cdef, [[ void* GetCurrentProcess(void); ]]);
pcall(ffi.cdef, [[ int K32GetProcessMemoryInfo(void* process, cc_pmc_t* counters, uint32_t cb); ]]);
pcall(ffi.cdef, [[ int GlobalMemoryStatusEx(cc_memstatus_t* status); ]]);

--[[ lua heap ]]--

local count = collectgarbage;
local k0, e0, k_end = 0, 0, nil;
local prof_start, prof_stop; -- (the line profiler, below)
-- clean: frames with neither gc steps nor trace events; jit: frames with trace
-- events (and the garbage they made, to show what tracing costs).
-- between: heap growth from one frame's end to the next one's start, and the
-- frames it was measured over (gc steps in between leave a frame out).
local acc = { alloc = 0, clean = 0, gc = 0, jit = 0, jit_alloc = 0, peak = 0, between = 0, nbetween = 0,
    frames = 0, threads = 0 };
local last = { alloc = 0, clean = 0, gc = 0, jit = 0, jit_alloc = 0, peak = 0, between = 0, frames = 0, threads = 0 };
local last_thread = false;

---the coroutine the present callback runs on, to count how often it changes.
function mem.event_thread(co)
    acc.frames = acc.frames + 1;
    if (co ~= last_thread) then
        acc.threads, last_thread = acc.threads + 1, co;
    end
end

function mem.frame_begin()
    k0, e0 = count('count'), events();
    if (k_end ~= nil and k0 >= k_end) then
        acc.between, acc.nbetween = acc.between + (k0 - k_end), acc.nbetween + 1;
    end
    if (prof_start ~= nil) then prof_start(); end
end

function mem.frame_end()
    if (prof_stop ~= nil) then prof_stop(); end
    local k = count('count');
    if (k < k0) then
        acc.gc = acc.gc + 1;
    elseif (events() ~= e0) then
        acc.jit, acc.jit_alloc = acc.jit + 1, acc.jit_alloc + (k - k0);
    else
        acc.alloc, acc.clean = acc.alloc + (k - k0), acc.clean + 1;
    end
    if (k > acc.peak) then acc.peak = k; end
    k_end = count('count');
end

-- sections, this window: name -> KB summed / samples, and trace events (whose
-- samples are left out of the sum). sec_last: name -> { bytes per frame, events }.
local sec_sum, sec_n, sec_ev, sec_last = {}, {}, {}, {};

---@return number heap, number events: now, to pass to mem.add
function mem.mark()
    return count('count'), events();
end

---adds the heap growth since mark to section `name`.
function mem.add(name, mark, ev)
    local d, e = count('count') - mark, events() - ev;
    if (sec_n[name] == nil) then sec_sum[name], sec_n[name], sec_ev[name] = 0, 0, 0; end
    if (e > 0) then
        sec_ev[name] = sec_ev[name] + e;
    elseif (d >= 0) then -- (< 0: the gc ran a step in here)
        sec_sum[name], sec_n[name] = sec_sum[name] + d, sec_n[name] + 1;
    end
end

---closes a stats window (the addon's 1s timing window).
function mem.roll()
    for name, n in pairs(sec_n) do
        local l = sec_last[name] or {};
        l.bytes = n > 0 and sec_sum[name] * 1024 / n or nil;
        l.events = sec_ev[name];
        sec_last[name] = l;
        sec_sum[name], sec_n[name], sec_ev[name] = 0, 0, 0;
    end
    last.alloc = acc.clean > 0 and acc.alloc * 1024 / acc.clean or 0;
    last.jit_alloc = acc.jit > 0 and acc.jit_alloc * 1024 / acc.jit or 0;
    last.between = acc.nbetween > 0 and acc.between * 1024 / acc.nbetween or 0;
    last.clean, last.gc, last.jit, last.peak = acc.clean, acc.gc, acc.jit, acc.peak;
    last.frames, last.threads = acc.frames, acc.threads;
    acc.alloc, acc.clean, acc.gc, acc.jit, acc.jit_alloc, acc.peak = 0, 0, 0, 0, 0, 0;
    acc.between, acc.nbetween, acc.frames, acc.threads = 0, 0, 0, 0;
end

---@return table { heap (KB), peak (KB, last window), alloc (bytes per clean frame), clean, gc, jit (frames),
---  jit_alloc (bytes per frame with trace events),
---  between (bytes per frame between frames), frames, threads (distinct callback coroutines) }
function mem.lua()
    return { heap = count('count'), peak = last.peak, alloc = last.alloc, clean = last.clean, gc = last.gc,
        jit = last.jit, jit_alloc = last.jit_alloc, between = last.between, frames = last.frames, threads = last.threads };
end

---runs a full collection.
---@return number before KB, number after KB
function mem.collect()
    local before = count('count');
    count('collect');
    return before, count('count');
end

---@return table { name, bytes|nil, events } by section, most garbage first. bytes
---is per frame without trace events in that section (nil if every one had some).
function mem.sections()
    local out = {};
    for name, l in pairs(sec_last) do out[#out + 1] = { name = name, bytes = l.bytes, events = l.events }; end
    table.sort(out, function (a, b) return (a.bytes or -1) > (b.bytes or -1); end);
    return out;
end

--[[ line profiler ]]--

-- a line hook during frames: the heap's growth between two line events is
-- charged to the line that ran in between (allocations in c functions, like
-- ashita's api, land on the line that called them). the hook's own garbage is
-- left out by re-reading the heap after it, and lines with trace events (the
-- jit still records while hooked) are dropped. code stays out of traces while
-- hooked, so this is what the interpreter allocates; traces can sink some.
local prof = nil; -- { src -> { line -> KB }, frames left, done callback }
local last_k, last_e, last_src, last_line = 0, 0, nil, nil;
local getinfo = debug.getinfo;

local function hook(_, line)
    local k = count('count');
    if (last_src ~= nil and k > last_k and events() == last_e) then
        local t = prof.lines[last_src];
        if (t == nil) then
            t = {};
            prof.lines[last_src] = t;
        end
        t[last_line] = (t[last_line] or 0) + (k - last_k);
    end
    last_src, last_line = getinfo(2, 'S').short_src, line;
    last_k, last_e = count('count'), events();
end

local function start()
    last_src = nil;
    debug.sethook(hook, 'l');
end

local function stop()
    debug.sethook();
    -- the last line before the hook went off
    local k = count('count');
    if (last_src ~= nil and k > last_k) then hook(nil, last_line); end
    prof.left = prof.left - 1;
    if (prof.left > 0) then return; end
    prof_start, prof_stop = nil, nil;
    local out = {};
    for src, t in pairs(prof.lines) do
        for line, kb in pairs(t) do
            out[#out + 1] = { where = ('%s:%d'):format(src, line), bytes = kb * 1024 / prof.frames };
        end
    end
    table.sort(out, function (a, b) return a.bytes > b.bytes; end);
    local done = prof.done;
    prof = nil;
    done(out);
end

---profiles the next n frames' allocations by source line, then calls
---done({ { where, bytes per frame } }, most first).
function mem.profile(n, done)
    prof = { lines = {}, left = n, frames = n, done = done };
    prof_start, prof_stop = start, stop;
end

--[[ textures ]]--

-- weak, so textures released by ffi.gc drop out when the gc collects them.
local tex_kind  = setmetatable({}, { __mode = 'k' });
local tex_bytes = setmetatable({}, { __mode = 'k' });

---records a texture's size. returns tex, to wrap a constructor's result.
function mem.texture(tex, kind, bytes)
    if (tex ~= nil) then
        tex_kind[tex], tex_bytes[tex] = kind, bytes;
    end
    return tex;
end

---forgets a texture that's being Released by hand.
function mem.release(tex)
    if (tex ~= nil) then
        tex_kind[tex], tex_bytes[tex] = nil, nil;
    end
end

---@return table kind -> { n, bytes }
function mem.textures()
    local out = {};
    for tex, kind in pairs(tex_kind) do
        local e = out[kind];
        if (e == nil) then
            e = { n = 0, bytes = 0 };
            out[kind] = e;
        end
        e.n, e.bytes = e.n + 1, e.bytes + (tex_bytes[tex] or 0);
    end
    return out;
end

--[[ process ]]--

---the whole game process: our share can't be told apart from the client's.
---@return table|nil { private, working_set, peak_working_set, va_used, va_total } bytes
function mem.process()
    local ok, out = pcall(function ()
        local pmc = ffi.new('cc_pmc_t');
        pmc.cb = ffi.sizeof(pmc);
        if (ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(), pmc, pmc.cb) == 0) then return nil; end
        local ms = ffi.new('cc_memstatus_t');
        ms.length = ffi.sizeof(ms);
        if (ffi.C.GlobalMemoryStatusEx(ms) == 0) then return nil; end
        return {
            private          = tonumber(pmc.private_bytes),
            working_set      = tonumber(pmc.working_set),
            peak_working_set = tonumber(pmc.peak_working_set),
            -- ffxi is 32-bit: running out of address space crashes it long
            -- before ram runs out.
            va_used          = tonumber(ms.total_virtual - ms.avail_virtual),
            va_total         = tonumber(ms.total_virtual),
        };
    end);
    return ok and out or nil;
end

return mem;
