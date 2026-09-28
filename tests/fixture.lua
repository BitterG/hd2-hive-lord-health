-- Test double for the HD2 engine Lua surface used by hivelord_probe.lua.
--
-- Design notes (these are the whole point of the fixture):
--   * Every engine entry point records itself in __CALLS, so a test can assert
--     exactly which engine functions the probe touched.
--   * The engine members the probe must NEVER call speculatively are present and
--     poisonous: calling one sets __SPECULATIVE_CALLED and raises.  In the real
--     game that is an access violation that pcall cannot catch; here the flag
--     survives the probe's pcall, which is what the assertion looks at.
--   * CRASH_ON_PROBE models a hard process death part-way through Stage D: the
--     driver simply stops calling update(), exactly like the game vanishing.
--     It is NOT a Lua error, because a Lua error would be catchable.

local real_os = os
local real_clock = real_os.clock

-- ============================================================ recorded state
_G.__CALLS = {}
_G.__SPECULATIVE_CALLED = nil
_G.__OBJECT_INFO_BAD = nil
_G.__DIED = false
_G.__PROBED = {}

local function rec(name) __CALLS[#__CALLS + 1] = name end

local APPDATA = os.getenv('HIVELORD_TEST_APPDATA')

-- Shadow the global os so the probe's config/log paths land in a temp dir.
os = {
    getenv = function(name) if name == 'APPDATA' then return APPDATA end return nil end,
    clock = real_clock,
    time = real_os.time,
    date = real_os.date,
}

-- ================================================================ fake world
-- GOID space.  Only these ids exist.
local OBJ = {}

local function obj(id, fields, otype)
    OBJ[id] = { fields = fields, type = otype or ('T' .. id) }
end

-- The Bastion-style hull: DRIVER HUD reads f[15] max and f[30] current.
local hull = {}
for i = 1, 35 do hull[i] = 0 end
hull[15] = 8000
hull[30] = 8000
hull[5] = 1; hull[6] = 1; hull[11] = 30; hull[22] = 15
obj(1, hull, 'hull')

-- Player character.
local player = {}
for i = 1, 12 do player[i] = 0 end
player[3] = 'un6y1d'
obj(2, player, 'un6y1d')

-- Ordinary junk with a few small unrelated numbers.
for id = 3, 20 do
    local f = {}
    for i = 1, 6 do f[i] = i end
    obj(id, f)
end

-- ==================================================== the fake HIVE LORD (goid 31)
-- Constellation taken from the offline parse of the plaintext
-- generated_entities.dl_bin: main 150000, nine 150000 zones, fourteen 35000
-- constitutions, thirteen/fourteen 15000 plate zones, one 20000 zone,
-- two 10000 mandibles, fourteen 5000 fins.
local function hive_lord_fields()
    local f = {}
    local function push(v) f[#f + 1] = v end
    push(150000)                 -- main
    for _ = 1, 9 do push(150000) end   -- crown, jaws, mouth, inner flesh x6
    for _ = 1, 2 do push(10000) end    -- mandibles
    for _ = 1, 13 do push(15000) end   -- plates
    push(20000)                        -- lower sterna plate
    for _ = 1, 14 do push(35000) end   -- constitution
    for _ = 1, 14 do push(5000) end    -- fins
    push(800)                          -- unit_mass
    push(0); push(0); push(0)
    return f
end
obj(31, hive_lord_fields(), 'un6y1d_hivelord')

-- ---------------------------------------------------------------- the decoys
-- Decoy A: exactly one 150000 plus assorted small numbers.  A threshold of
-- "distinct magic >= 1" or even ">= 4" with the wrong membership would let this
-- through; the real criterion must reject it.
local decoy_a = { 150000, 35000, 15000, 5000, 100, 42, 7, 1 }
obj(40, decoy_a, 'decoy_a')

-- Decoy B: many magic values but only two 150000s -- a real but damaged
-- non-Hive-Lord entity, e.g. a Bile Titan's own zone table.
local decoy_b = { 150000, 150000, 35000, 35000, 15000, 15000, 5000, 5000, 8000, 8000, 2500 }
obj(41, decoy_b, 'decoy_b')

-- Decoy C: looks like a full Hive Lord but has no 150000 at all.
local decoy_c = {}
do
    local f = decoy_c
    for _ = 1, 14 do f[#f + 1] = 35000 end
    for _ = 1, 14 do f[#f + 1] = 15000 end
    for _ = 1, 14 do f[#f + 1] = 5000 end
    f[#f + 1] = 20000; f[#f + 1] = 10000; f[#f + 1] = 800
end
obj(42, decoy_c, 'decoy_c')

-- ============================================================ engine doubles
local EXISTING = {}
for id in pairs(OBJ) do EXISTING[id] = true end

local SESSION = { name = 'fake-session' }
local PEER = 7

local WORLD = { name = 'fake-mission-world' }

-- When set, objects_owned_by returns an empty list for the first N update ticks,
-- which is how "we are on the ship" is modelled.
_G.__SHIP_TICKS = 0
local ship_remaining = 0

_G.__CRASH_ON_PROBE = nil

local GS = {}
GS.game_object_exists = function(session, id)
    rec('GS.game_object_exists')
    return EXISTING[id] == true
end
GS.game_object_field_batched = function(session, id, filter)
    rec('GS.game_object_field_batched')
    if __CRASH_ON_PROBE == id then
        __DIED = true
        rec('GS.game_object_field_batched:DIED:' .. tostring(id))
        return nil
    end
    __PROBED[#__PROBED + 1] = id
    local o = OBJ[id]
    if not o then return nil end
    -- Hand back a copy, as the engine hands back a fresh table.
    local copy = {}
    for i = 1, #o.fields do copy[i] = o.fields[i] end
    return copy
end
GS.game_object_field = function(session, id, name) rec('GS.game_object_field') return nil end
GS.game_object_is_type = function(session, id, t)
    rec('GS.game_object_is_type')
    local o = OBJ[id]
    return o ~= nil and o.type == t
end
GS.in_session = function(session) rec('GS.in_session') return true end
GS.objects_owned_by = function(session, peer)
    rec('GS.objects_owned_by')
    if ship_remaining > 0 then ship_remaining = ship_remaining - 1; return {} end
    return { 1, 2 }
end

-- Poison: a speculative call must be visible even though the probe pcalls.
GS.set_game_object_field = function(...)
    __SPECULATIVE_CALLED = 'GS.set_game_object_field'
    error('speculative engine call')
end
GS.object_types = function(...)
    __SPECULATIVE_CALLED = 'GS.object_types'
    error('speculative engine call')
end

local Net = {}
Net.game_session = function() rec('Net.game_session') return SESSION end
Net.peer_id = function() rec('Net.peer_id') return PEER end
Net.object_info = function(t)
    rec('Net.object_info')
    if t == nil or t == 'rHVbvgIu' then
        if t == nil then __OBJECT_INFO_BAD = true; error('object_info with no type') end
        local fields = {}
        for i = 1, 27 do fields[i] = { id = string.format('%08x', i) } end
        return { fields = fields }
    end
    __OBJECT_INFO_BAD = tostring(t)
    error('unknown object type')
end
-- Poison members the probe must never invoke blind.
Net.all_objects = function(...)
    __SPECULATIVE_CALLED = 'Net.all_objects'
    error('speculative engine call')
end
Net.object_types = function(...)
    __SPECULATIVE_CALLED = 'Net.object_types'
    error('speculative engine call')
end
Net.objects_in_world = function(...)
    __SPECULATIVE_CALLED = 'Net.objects_in_world'
    error('speculative engine call')
end

local App = {}
App.worlds = function() rec('App.worlds') return { WORLD } end
App.main_world = function() rec('App.main_world') return WORLD end

_G.stingray = {
    GameSession = GS,
    Network = Net,
    Application = App,
    World = {},
    Gui = {},
}

_G.CowboyBingusModLoader = { api = 1, version = 16, modules = {} }

-- The loader requires an existing global update to chain.
if type(_G.update) ~= 'function' then _G.update = function(...) end end

-- ============================================================ driver helpers
function __set_ship_ticks(n) ship_remaining = n __SHIP_TICKS = n end
function __calls_text() return table.concat(__CALLS, '\n') end
function __distinct_calls()
    local seen, out = {}, {}
    for _, c in ipairs(__CALLS) do
        if not seen[c] then seen[c] = true; out[#out + 1] = c end
    end
    table.sort(out)
    return table.concat(out, ',')
end
function __probed_text()
    local p = {}
    for _, v in ipairs(__PROBED) do p[#p + 1] = tostring(v) end
    return table.concat(p, ',')
end
function __calls_reset() __CALLS = {} end
