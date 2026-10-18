--[[
* skillchains in progress on the monsters the party is fighting, read from
* action packets (0x028), for the target panel and the skillchain component.
*
* each monster the party has a chain going on gets a record of its resonance
* (the opener's skillchain properties, or the skillchain made since) and the
* window for the next step: a few seconds after the last step lands
* (BASE_DELAY, plus the action's own `delay`), then open for BASE_WINDOW.
* whether the last step made a skillchain (and so can be magic burst) or only
* opened one is kept too. a miss leaves all of it alone.
*
* each record also keeps the chain's steps: every weaponskill (or chaining
* spell / monster ability) with its damage, the skillchain it made and its
* damage, and the magic bursts on that skillchain. a step that makes no
* skillchain starts the chain over. a monster is dropped LINGER seconds after
* its window closes.
*
* only the party's own actions count (members, trusts, and their pets). the
* server sends some packets twice, so recent actions are remembered and
* repeats ignored.
*
* ported from xitools' skillchain addon (retail data only).
--]]

local weaponskills = require('game.scdata.weaponskills');
local mobskills    = require('game.scdata.mobskills');
local magicskills  = require('game.scdata.magicskills');

local unpack_be = ashita.bits.unpack_be;

local skillchain = {};

local BASE_DELAY = 4;  -- seconds after a step before the next can chain
local BASE_WINDOW = 6; -- seconds the window then stays open
local REPEATS = 32;    -- recent action packets remembered, to drop repeats
local PRUNE = 1;       -- seconds between dropping finished monsters
local MAX_STEPS = 16;  -- steps kept per chain, oldest dropped first
local MAX_BURSTS = 16; -- magic bursts kept per skillchain

---seconds a finished chain is kept after its window closes, to show it ended.
skillchain.LINGER = 6;

-- action categories
local CAT_WS, CAT_SPELL, CAT_JA, CAT_MOBSKILL, CAT_PETSKILL = 3, 4, 6, 11, 13;
-- weaponskill messages that can chain (not jumps, steals, ...)
local WS_MSGS = { [103] = true, [185] = true, [187] = true, [188] = true, [238] = true };
-- job abilities that let the next spell chain, and for how long (seconds)
local CHAIN_SPELLS = { [94] = 30, [317] = 60 }; -- chain affinity, immanence
-- spell messages for a magic burst (the magicBurstMessage values in the
-- server's spell_list), and those of them whose number is damage: damage and
-- hp drained. the rest are mp drained or an effect.
local BURST_MSGS = { [252] = true, [268] = true, [271] = true, [274] = true, [275] = true };
local BURST_DAMAGE = { [252] = true, [274] = true };

-- skillchain message -> the skillchain it made
local CHAINS = {
    [0x120] = 'Light', [0x121] = 'Darkness', [0x122] = 'Gravitation', [0x123] = 'Fragmentation',
    [0x124] = 'Distortion', [0x125] = 'Fusion', [0x126] = 'Compression', [0x127] = 'Liquefaction',
    [0x128] = 'Induration', [0x129] = 'Reverberation', [0x12A] = 'Transfixion', [0x12B] = 'Scission',
    [0x12C] = 'Detonation', [0x12D] = 'Impaction', [0x12E] = 'Radiance', [0x12F] = 'Umbra',
    [0x181] = 'Light', [0x182] = 'Darkness', [0x183] = 'Gravitation', [0x184] = 'Fragmentation',
    [0x185] = 'Distortion', [0x186] = 'Fusion', [0x187] = 'Compression', [0x188] = 'Liquefaction',
    [0x189] = 'Induration', [0x18A] = 'Reverberation', [0x18B] = 'Transfixion', [0x18C] = 'Scission',
    [0x18D] = 'Detonation', [0x18E] = 'Impaction',
    [0x2FF] = 'Radiance', [0x300] = 'Umbra', [0x301] = 'Radiance', [0x302] = 'Umbra',
};

-- resonance -> its elements
skillchain.ELEMENTS = {
    Light         = { 'Wind', 'Thunder', 'Fire', 'Light' },
    Darkness      = { 'Ice', 'Water', 'Earth', 'Dark' },
    Gravitation   = { 'Earth', 'Dark' },
    Fragmentation = { 'Thunder', 'Wind' },
    Distortion    = { 'Ice', 'Water' },
    Fusion        = { 'Fire', 'Light' },
    Compression   = { 'Dark' },
    Liquefaction  = { 'Fire' },
    Induration    = { 'Ice' },
    Reverberation = { 'Water' },
    Transfixion   = { 'Light' },
    Scission      = { 'Earth' },
    Detonation    = { 'Wind' },
    Impaction     = { 'Thunder' },
    Radiance      = { 'Wind', 'Thunder', 'Fire', 'Light' },
    Umbra         = { 'Ice', 'Water', 'Earth', 'Dark' },
};

-- property -> what can follow it: { second property, skillchain made }, ...
local COMBOS = {
    Transfixion   = { { 'Compression', 'Compression' }, { 'Scission', 'Distortion' }, { 'Reverberation', 'Reverberation' } },
    Compression   = { { 'Transfixion', 'Transfixion' }, { 'Detonation', 'Detonation' } },
    Liquefaction  = { { 'Scission', 'Scission' }, { 'Impaction', 'Fusion' } },
    Scission      = { { 'Liquefaction', 'Liquefaction' }, { 'Reverberation', 'Reverberation' }, { 'Detonation', 'Detonation' } },
    Reverberation = { { 'Induration', 'Induration' }, { 'Impaction', 'Impaction' } },
    Detonation    = { { 'Compression', 'Gravitation' }, { 'Scission', 'Scission' } },
    Induration    = { { 'Compression', 'Compression' }, { 'Reverberation', 'Fragmentation' }, { 'Impaction', 'Impaction' } },
    Impaction     = { { 'Liquefaction', 'Liquefaction' }, { 'Detonation', 'Detonation' } },
    Gravitation   = { { 'Distortion', 'Darkness' }, { 'Fragmentation', 'Fragmentation' } },
    Distortion    = { { 'Gravitation', 'Darkness' }, { 'Fusion', 'Fusion' } },
    Fusion        = { { 'Gravitation', 'Gravitation' }, { 'Fragmentation', 'Light' } },
    Fragmentation = { { 'Distortion', 'Distortion' }, { 'Fusion', 'Light' } },
    Light         = { { 'Light', 'Light' } },
    Darkness      = { { 'Darkness', 'Darkness' } },
};

---monster records, by server id: { resonance, chained, since, opens, closes,
---steps }. resonance: a list of names; chained: true if the last step made a
---skillchain (burstable), false for an opener; since: when the step that set
---the window landed; opens, closes: the window. steps: oldest first, each
---{ name, dmg, sc = { name, dmg } or nil, bursts = { { name, dmg or nil }, ... } or nil }.
skillchain.mobs = {};

local chain_spell = {}; -- actor server id -> time chain affinity / immanence runs out
local pruned = 0;       -- when monsters were last pruned
local seen, seen_at = {}, 0; -- recent action packets, a ring

---seconds, sub-second resolution.
function skillchain.now()
    return ashita.time.clock().ms / 1000;
end

--[[ chains ]]--

---a step landing on monster `id` at time `t`: `name` with skillchain
---properties `attr` (and `delay` extra seconds before its window opens) for
---`dmg`, making skillchain `sc` for `sc_dmg` if sc isn't nil.
local function land(id, t, name, attr, delay, dmg, sc, sc_dmg)
    local m = skillchain.mobs[id];
    local step = { name = name, dmg = dmg };
    if (sc ~= nil) then step.sc = { name = sc, dmg = sc_dmg }; end
    if (m == nil or sc == nil) then -- an opener starts the chain over
        m = { steps = {} };
        skillchain.mobs[id] = m;
    end
    local steps = m.steps;
    if (#steps >= MAX_STEPS) then table.remove(steps, 1); end
    steps[#steps + 1] = step;
    local opens = t + BASE_DELAY + (delay or 0);
    m.resonance, m.chained = sc ~= nil and { sc } or attr, sc ~= nil;
    m.since, m.opens, m.closes = t, opens, opens + BASE_WINDOW;
end

---a magic burst of spell `name` (for `dmg`, or nil) on monster `id`: kept
---with the step that made the skillchain it bursts.
local function burst(id, name, dmg)
    local m = skillchain.mobs[id];
    if (m == nil or not m.chained) then return; end
    local step = m.steps[#m.steps];
    if (step == nil or step.sc == nil) then return; end
    step.bursts = step.bursts or {};
    if (#step.bursts < MAX_BURSTS) then
        step.bursts[#step.bursts + 1] = { name = name, dmg = dmg };
    end
end

-- resonance list -> what can follow it, made on first ask
local combo_cache = setmetatable({}, { __mode = 'k' });

---the skillchain properties that can follow resonance `res` to make a
---skillchain, each once, in the order they're found.
---@return table names
function skillchain.combos(res)
    local out = combo_cache[res];
    if (out ~= nil) then return out; end
    out = {};
    local have = {};
    for _, p in ipairs(res) do
        for _, c in ipairs(COMBOS[p] or {}) do
            if (not have[c[1]]) then
                have[c[1]] = true;
                out[#out + 1] = c[1];
            end
        end
    end
    combo_cache[res] = out;
    return out;
end

--[[ who's who ]]--

local party_ids = {};

---the party's (and their pets') server ids, read fresh: only needed when an
---action that could chain arrives.
local function read_party()
    for k in pairs(party_ids) do party_ids[k] = nil; end
    local mm = AshitaCore:GetMemoryManager();
    local party, ent = mm:GetParty(), mm:GetEntity();
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) ~= 0) then
            local sid = party:GetMemberServerId(i);
            if (sid ~= 0) then party_ids[sid] = true; end
            local idx = party:GetMemberTargetIndex(i);
            local pet = idx ~= 0 and ent:GetPetTargetIndex(idx) or 0;
            if (pet ~= 0) then party_ids[ent:GetServerId(pet)] = true; end
        end
    end
end

--[[ action packets ]]--

---the parts of an action packet we need: actor, category, param, and the first
---target's actions (each with its number, and any skillchain on it and its damage).
local function parse(p)
    local a = {
        actor    = unpack_be(p, 40, 32),
        category = unpack_be(p, 82, 4),
        param    = unpack_be(p, 86, 32),
        target   = nil,
        actions  = {},
    };
    if (unpack_be(p, 72, 6) == 0) then return a; end
    local off = 150;
    a.target = unpack_be(p, off, 32);
    for j = 1, unpack_be(p, off + 32, 4) do
        local act = {
            miss    = unpack_be(p, off + 36, 3),
            param   = unpack_be(p, off + 63, 17),
            message = unpack_be(p, off + 80, 10),
        };
        if (unpack_be(p, off + 121, 1) == 1) then
            act.proc_param = unpack_be(p, off + 132, 17);
            act.proc_message = unpack_be(p, off + 149, 10);
            off = off + 37;
        end
        if (unpack_be(p, off + 122, 1) == 1) then
            off = off + 34;
        end
        off = off + 87;
        a.actions[j] = act;
    end
    return a;
end

---an action that can open or continue a chain. info: its data entry (attr:
---its skillchain properties; delay: extra seconds before its window opens).
---msgs: the messages that count, or nil for all.
local function chain_step(a, info, msgs)
    if (a.target == nil or info == nil or info.attr == nil) then return; end
    local t = skillchain.now();
    for _, act in ipairs(a.actions) do
        if (msgs ~= nil and not msgs[act.message]) then return; end -- not a chaining ws
        if (act.miss == 0) then
            -- landed without a skillchain (or with some other added effect): a fresh opener
            local sc = act.proc_message ~= nil and CHAINS[act.proc_message] or nil;
            land(a.target, t, info.name or '?', info.attr, info.delay, act.param, sc, sc and act.proc_param);
        end
    end
end

local spell_names = {};

---a spell's english name, from the client's resources.
local function spell_name(id)
    local n = spell_names[id];
    if (n == nil) then
        local res = AshitaCore:GetResourceManager():GetSpellById(id);
        n = res and res.Name[1] or ('spell %d'):format(id);
        spell_names[id] = n;
    end
    return n;
end

---magic bursts in a spell's actions.
local function bursts(a)
    if (a.target == nil) then return; end
    for _, act in ipairs(a.actions) do
        if (BURST_MSGS[act.message]) then
            burst(a.target, spell_name(a.param), BURST_DAMAGE[act.message] and act.param or nil);
        end
    end
end

local function handle(a)
    local cat, param = a.category, a.param;
    if (cat == CAT_WS) then
        -- some trusts send their monster abilities as weaponskills
        if (param > 256) then
            chain_step(a, mobskills[param]);
        else
            chain_step(a, weaponskills[param], WS_MSGS);
        end
    elseif (cat == CAT_SPELL) then
        bursts(a);
        local until_ = chain_spell[a.actor];
        if (until_ ~= nil and skillchain.now() <= until_) then
            chain_spell[a.actor] = nil;
            chain_step(a, magicskills[param]);
        end
    elseif (cat == CAT_MOBSKILL or cat == CAT_PETSKILL) then
        chain_step(a, mobskills[param]);
    elseif (cat == CAT_JA and CHAIN_SPELLS[param] ~= nil) then
        chain_spell[a.actor] = skillchain.now() + CHAIN_SPELLS[param];
    end
end

-- categories worth parsing a packet for
local WANTED = { [CAT_WS] = true, [CAT_SPELL] = true, [CAT_JA] = true, [CAT_MOBSKILL] = true, [CAT_PETSKILL] = true };

---true if this exact packet arrived recently (and remembers it). the header's
---sync counter (bytes 2-3) differs from packet to packet, so two real actions
---that happen to match still count separately.
local function repeated(data)
    for i = 1, REPEATS do
        if (seen[i] == data) then return true; end
    end
    seen_at = seen_at % REPEATS + 1;
    seen[seen_at] = data;
    return false;
end

function skillchain.packet_in(e)
    if (e.id ~= 0x028) then return; end
    local p = e.data_modified_raw;
    if (not WANTED[unpack_be(p, 82, 4)]) then return; end
    read_party();
    if (not party_ids[unpack_be(p, 40, 32)]) then return; end
    if (repeated(e.data_modified)) then return; end
    handle(parse(p));
end

-- a made-up chain for play(), played out over time: seconds from the start,
-- then a step (name, properties, damage, skillchain made and its damage) or
-- a magic burst (spell, damage or nil)
local SCRIPT = {
    { 0,    'ws', 'Savage Blade', { 'Fragmentation', 'Scission' }, 3412 },
    { 5,    'ws', 'Knights of Round', { 'Light', 'Fusion' }, 2874, 'Light', 2311 },
    { 6.2,  'mb', 'Thunder V', 8123 },
    { 6.9,  'mb', 'Aero V', 7406 },
    { 7.6,  'mb', 'Distract III', nil },
    { 11,   'ws', 'Chant du Cygne', { 'Light', 'Distortion' }, 4210, 'Light', 3980 },
    { 12.4, 'mb', 'Fire V', 9876 },
};
local playing = nil; -- { id, start, next } while play()'s chain runs

---runs play()'s chain's events that are due.
local function play(t)
    if (playing == nil) then return; end
    local ev = SCRIPT[playing.next];
    while (ev ~= nil and t - playing.start >= ev[1]) do
        if (ev[2] == 'ws') then
            land(playing.id, t, ev[3], ev[4], nil, ev[5], ev[6], ev[7]);
        else
            burst(playing.id, ev[3], ev[4]);
        end
        playing.next = playing.next + 1;
        ev = SCRIPT[playing.next];
    end
    if (ev == nil) then playing = nil; end
end

---plays a made-up chain on the monster with server id `id` over the next
---several seconds: an opener, two skillchains and their magic bursts.
function skillchain.play(id)
    playing = { id = id, start = skillchain.now(), next = 1 };
end

---drops monsters whose window has closed, at most once every PRUNE seconds.
---call every frame.
function skillchain.tick(t)
    play(t);
    if (t - pruned < PRUNE) then return; end
    pruned = t;
    for id, m in pairs(skillchain.mobs) do
        if (m.closes + skillchain.LINGER < t) then skillchain.mobs[id] = nil; end
    end
end

-- made-up resonances for demo(), in turn: every skillchain (made by one, so
-- burstable), level 1 up to 4, then two openers: two properties, and three
-- (Disaster's: too wide in full, so shortened)
local DEMOS = {
    { 'Transfixion', chained = true }, { 'Compression', chained = true }, { 'Liquefaction', chained = true },
    { 'Scission', chained = true }, { 'Reverberation', chained = true }, { 'Detonation', chained = true },
    { 'Induration', chained = true }, { 'Impaction', chained = true },
    { 'Gravitation', chained = true }, { 'Distortion', chained = true }, { 'Fusion', chained = true },
    { 'Fragmentation', chained = true },
    { 'Light', chained = true }, { 'Darkness', chained = true },
    { 'Radiance', chained = true }, { 'Umbra', chained = true },
    { 'Fragmentation', 'Scission' }, { 'Transfixion', 'Scission', 'Gravitation' },
};
local next_demo = 1;

---a made-up chain on the monster with server id `id`, to see it without a
---party. each call shows the next of the resonances above; returns a
---description of the one shown.
function skillchain.demo(id)
    local t = skillchain.now();
    local i, demo = next_demo, DEMOS[next_demo];
    skillchain.mobs[id] = { resonance = demo, chained = demo.chained == true, since = t, opens = t + 2, closes = t + 2 + BASE_WINDOW, steps = {} };
    next_demo = next_demo % #DEMOS + 1;
    return ('%d/%d %s%s'):format(i, #DEMOS, table.concat(demo, ', '), demo.chained and '' or ' (opener)');
end

return skillchain;
