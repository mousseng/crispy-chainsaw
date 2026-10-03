--[[
* skillchains in progress on the monsters the party is fighting, read from
* action packets (0x028), for the target panel.
*
* each monster the party has a chain going on gets a record of its resonance
* (the opener's skillchain properties, or the skillchain made since) and the
* window for the next step: a few seconds after the last step lands
* (BASE_DELAY, plus the action's own `delay`), then open for BASE_WINDOW. a
* miss leaves both alone. a monster is dropped once its window closes.
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

-- action categories
local CAT_WS, CAT_SPELL, CAT_JA, CAT_MOBSKILL, CAT_PETSKILL = 3, 4, 6, 11, 13;
-- weaponskill messages that can chain (not jumps, steals, ...)
local WS_MSGS = { [103] = true, [185] = true, [187] = true, [188] = true, [238] = true };
-- job abilities that let the next spell chain, and for how long (seconds)
local CHAIN_SPELLS = { [94] = 30, [317] = 60 }; -- chain affinity, immanence

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

---monster records, by server id: { resonance, since, opens, closes }.
---resonance: a list of names; since: when the step that set the window
---landed; opens, closes: the window.
skillchain.mobs = {};

local chain_spell = {}; -- actor server id -> time chain affinity / immanence runs out
local pruned = 0;       -- when monsters were last pruned
local seen, seen_at = {}, 0; -- recent action packets, a ring

---seconds, sub-second resolution.
function skillchain.now()
    return ashita.time.clock().ms / 1000;
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
---target's actions (with any skillchain on them).
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
            message = unpack_be(p, off + 80, 10),
        };
        if (unpack_be(p, off + 121, 1) == 1) then
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
    local opens = t + BASE_DELAY + (info.delay or 0);
    for _, act in ipairs(a.actions) do
        if (msgs ~= nil and not msgs[act.message]) then return; end -- not a chaining ws
        if (act.miss == 0) then
            local resonance = info.attr; -- landed without a skillchain: a fresh opener
            if (act.proc_message ~= nil) then
                local sc = CHAINS[act.proc_message];
                resonance = sc and { sc } or nil;
            end
            if (resonance ~= nil) then
                skillchain.mobs[a.target] = { resonance = resonance, since = t, opens = opens, closes = opens + BASE_WINDOW };
            end
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

---drops monsters whose window has closed, at most once every PRUNE seconds.
---call every frame.
function skillchain.tick(t)
    if (t - pruned < PRUNE) then return; end
    pruned = t;
    for id, m in pairs(skillchain.mobs) do
        if (m.closes < t) then skillchain.mobs[id] = nil; end
    end
end

-- made-up resonances for test(), in turn: two elements, four, an opener's two
-- properties, then three (Disaster's: too wide in full, so shortened)
local TESTS = {
    { 'Fusion' }, { 'Light' }, { 'Fragmentation', 'Scission' },
    { 'Transfixion', 'Scission', 'Gravitation' },
};
local next_test = 1;

---a made-up chain on the monster with server id `id`, to see it without a
---party. each call shows the next of a few resonances.
function skillchain.test(id)
    local t = skillchain.now();
    skillchain.mobs[id] = { resonance = TESTS[next_test], since = t, opens = t + 2, closes = t + 2 + BASE_WINDOW };
    next_test = next_test % #TESTS + 1;
end

return skillchain;
