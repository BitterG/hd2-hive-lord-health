-- Test double for the engine surface used by hivelord_hp.lua.
--
-- Type-strict, like the other two fixtures, and it additionally models damage:
-- `__damage(main, zone)` mutates the live fields so the reader's self-calibration
-- has something real to observe.  The field array is laid out to match the
-- byte-exact Hive Lord parse: main max, main current, then 38 zone healths and
-- 14 constitutions.

local real_os = os
local function rec(s) __CALLS[#__CALLS + 1] = s end

_G.__CALLS = {}
_G.__SPECULATIVE_CALLED = nil
_G.__GUI_TEXTS = {}
_G.__GUI_CREATED = 0
_G.__GUI_DESTROYED = 0
-- Text handles have to be unique and have to be tracked, or the fixture cannot tell a
-- correct destroy from a bogus one.  Returning a constant 1 and ignoring the argument was
-- hiding a real bug: the mod remembered 0 and 1 instead of the handles it was given, so
-- nothing was ever destroyed and every redraw stacked another pair of lines.
_G.__GUI_NEXT_ID = 0
_G.__GUI_LIVE = {}
_G.__GUI_DESTROY_IDS = {}
-- What is on screen right now, as opposed to every string ever drawn.  __gui_texts() is
-- cumulative and therefore cannot answer "is a stale reading still up?", which is the
-- actual question.
_G.__GUI_TEXT_BY_ID = {}

local APPDATA = os.getenv('HIVELORD_TEST_APPDATA')
os = {
    getenv = function(name) if name == 'APPDATA' then return APPDATA end return nil end,
    clock = real_os.clock, time = real_os.time, date = real_os.date,
    -- Needed by the durable-write path.  Omitting them made the addon error at
    -- load, which is itself worth knowing: a reduced `os` must not be fatal.
    remove = real_os.remove, rename = real_os.rename,
}

-- ============================================================== fake objects
local OBJ = {}
local function obj(id, fields, otype) OBJ[id] = { fields = fields, type = otype } end

-- The Hive Lord, in the shape it was MEASURED to have on the wire (FINDINGS.md §22.1,
-- §23).  The previous fixture encoded a guess -- that the object carries an absolute
-- current-health field -- and a whole live fight disproved it: followed from full
-- health to destruction, not one of the 46 networked fields ever reached zero, and the
-- only damage-shaped field read 61/63 at the instant the entity died.  The client's
-- runtime health type, `SyncedHealthComponent`, is four bytes wide, so an absolute
-- 150000 plus 38 zone values cannot be present client-side at all.
--
--   index 7   the six-bit synchronised fraction k/63   (the current value)
--   index 17  the 150000 maximum                       (never moves)
--   index 44  the 14-bit damage mask                   (only ever falls)
local SYNC_IDX, MAIN_MAX_IDX, MASK_IDX = 7, 17, 44

local function hive_lord_fields()
    local f = {}
    for i = 1, 46 do f[i] = 0 end
    f[SYNC_IDX] = 61 / 63
    f[MAIN_MAX_IDX] = 150000
    f[MASK_IDX] = 16383
    -- Other constants copied verbatim from the real object.  256/255 and 254/255 are
    -- deliberately in range-adjacent positions: they are near 1 but are NOT k/63 for
    -- any k, so they are what proves the fraction is found by its quantisation rather
    -- than by "it is the only value below 1".
    f[16] = 699050
    f[23] = 64
    f[36] = 256 / 255
    f[37] = 256 / 255
    f[38] = 254 / 255
    f[40] = 254 / 255
    f[5] = 3
    return f
end

local hl = hive_lord_fields()
obj(31, hl, 'un6y1d_hivelord')

-- Bastion-style hull: max at 15, current at 30, small field count.
local hull = {}
for i = 1, 35 do hull[i] = 0 end
hull[15] = 8000
hull[30] = 8000
obj(1, hull, 'hull')

local player = {}
for i = 1, 12 do player[i] = 0 end
obj(2, player, 'un6y1d')

-- Ordinary junk.
for id = 3, 25 do
    local f = {}
    for i = 1, 6 do f[i] = i end
    obj(id, f, 'junk' .. id)
end

-- Decoy: a single 150000 with a few other magic numbers.  Must not be accepted
-- as a Hive Lord.
obj(40, { 150000, 35000, 15000, 5000, 100, 42 }, 'decoy_a')

-- A large object holding NO value the reader recognises at all.  The shape dump must
-- still capture it: requiring a recognised value to dump is exactly how a target whose
-- array looks different in another mission stays invisible -- which is what happened
-- when a Hive Lord was fought and killed with the reader running and nothing at all was
-- recorded about the large objects in that mission.
local big = {}
for i = 1, 24 do big[i] = 7 * i end
obj(50, big, 'big_unrecognised')

-- A "sparse" Hive Lord: what the array would look like if the network field list
-- carries only scalar state (main max + main current) and no zone strand, which is
-- exactly the shape the shipped DRIVER HUD reads for its hull.  It must NOT pass
-- the strong gate, but it must still be captured and ranked.
local sparse = {}
for i = 1, 40 do sparse[i] = 0 end
sparse[6] = 150000
sparse[7] = 150000
sparse[9] = 8000
sparse[10] = 800
obj(32, sparse, 'un6y1d_hivelord_sparse')

-- ============================================================ engine doubles
local EXISTING = {}
for id in pairs(OBJ) do EXISTING[id] = true end

local SESSION_PEER = 'e5767462040a0ff9'
local WORLD, UIWORLD = { name = 'mission' }, { name = 'ui' }
local ship_remaining = 0
local IN_SESSION_OVERRIDE = nil

-- The engine hands back a fresh wrapper on every call.  This is not a quirk of
-- the fixture: the first live log showed `SESSION_CHANGE` on every single frame
-- because `session ~= M.session` was always true, which reset the object sweep
-- continuously and stopped it ever getting past id 903.  Reproducing it here is
-- what makes the regression testable.  tostring() renders the handle's content,
-- which is stable, so it is the only safe thing to compare.
-- A FRESH wrapper per call, exactly as the engine does.  The live log proved this for
-- sessions and the main world: identity comparison there was true every frame, the reset
-- fired continuously and the object sweep restarted from id 1 forever.  A fixture with
-- stable handles would hide any regression back to comparing identity.
local function handle(render)
    return setmetatable({}, { __tostring = function() return render end })
end
local function session_handle() return handle('[GameSession]') end
local function world_handle() return handle('[World]') end
local function ui_world_handle()
    -- After the drop, a mission change means the old UI world is simply gone and a new
    -- one has replaced it: what the HUD was created on no longer renders the same.
    if rawget(_G, '__GUI_WORLD_GONE') then return handle('[UIWorld-2]') end
    return handle('[UIWorld]')
end
local function peer_handle() return handle(SESSION_PEER) end

local GS = {}
GS.game_object_exists = function(s, id) rec('GS.game_object_exists') return EXISTING[id] == true end
GS.game_object_field_batched = function(s, id, filter)
    rec('GS.game_object_field_batched')
    local o = OBJ[id]
    if not o then return nil end
    local copy = {}
    for i = 1, #o.fields do copy[i] = o.fields[i] end
    return copy
end
GS.game_object_field = function() rec('GS.game_object_field') return nil end
GS.game_object_is_type = function(s, id, t)
    rec('GS.game_object_is_type')
    return OBJ[id] ~= nil and OBJ[id].type == t
end
GS.in_session = function()
    rec('GS.in_session')
    if IN_SESSION_OVERRIDE ~= nil then return IN_SESSION_OVERRIDE end
    return true
end
GS.objects_owned_by = function()
    rec('GS.objects_owned_by')
    if ship_remaining > 0 then ship_remaining = ship_remaining - 1; return {} end
    return { 1, 2 }
end
GS.set_game_object_field = function() __SPECULATIVE_CALLED = 'GS.set_game_object_field'
    error('speculative') end

local Net = {}
Net.game_session = function() rec('Net.game_session') return session_handle() end
Net.peer_id = function() rec('Net.peer_id') return peer_handle() end
Net.object_info = function(t)
    rec('Net.object_info')
    if t == nil then __SPECULATIVE_CALLED = 'Net.object_info(nil)'; error('nil type') end
    -- DRIVER HUD documents this type as having 27 fields, and the liveness check
    -- asserts that number, so the fixture must reproduce it rather than 0.
    local fields = {}
    for i = 1, 27 do fields[i] = { id = string.format('%08x', i) } end
    return { fields = fields }
end
Net.all_objects = function() __SPECULATIVE_CALLED = 'Net.all_objects'; error('speculative') end

local App = {}
-- Two worlds, like the real game: the HUD surface belongs on the one that is not
-- the mission world.  Both are fresh wrappers each call.
App.worlds = function() rec('App.worlds') return { world_handle(), ui_world_handle() } end
App.main_world = function() rec('App.main_world') return world_handle() end

local Gui = {}
Gui.resolution = function() rec('Gui.resolution') return 1920, 1080 end
Gui.text = function(gui, s, font, size, font2, pos, col)
    rec('Gui.text')
    __GUI_TEXTS[#__GUI_TEXTS + 1] = tostring(s)
    -- Unique handle per call, exactly like the engine: a constant here would make a
    -- bogus destroy indistinguishable from a correct one.
    __GUI_NEXT_ID = __GUI_NEXT_ID + 1
    __GUI_LIVE[__GUI_NEXT_ID] = true
    __GUI_TEXT_BY_ID[__GUI_NEXT_ID] = tostring(s)
    return __GUI_NEXT_ID
end
Gui.triangle = function() rec('Gui.triangle') return 2 end
Gui.destroy_text = function(gui, id)
    rec('Gui.destroy_text')
    if id == nil then error('Gui.destroy_text: called without a handle') end
    __GUI_DESTROY_IDS[#__GUI_DESTROY_IDS + 1] = id
    __GUI_LIVE[id] = nil
    __GUI_TEXT_BY_ID[id] = nil
    return true
end
Gui.destroy_triangle = function() rec('Gui.destroy_triangle') return true end

local World = {}
World.create_screen_gui = function()
    rec('World.create_screen_gui')
    __GUI_CREATED = __GUI_CREATED + 1
    return { gui = true }
end
World.destroy_gui = function()
    rec('World.destroy_gui')
    __GUI_DESTROYED = __GUI_DESTROYED + 1
    return true
end

_G.stingray = {
    GameSession = GS, Network = Net, Application = App, World = World, Gui = Gui,
    Vector2 = function(x, y) return { x = x, y = y } end,
    Vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
    Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
    -- Mirrors what the game's own Lua reads (see work/hivelord/gamelua_api.py):
    -- these tables must be listed by the namespace dump.
    EntityManager = { instances_with_tag_in_entity = function() end,
                      entity_data = function() end, Entity = {}, lookup = function() end },
    components = { VFGlobalDirection = {}, HealthComponent = {}, UnitComponent = {} },
    DataComponent = { get_property = function() end, set_property = function() end },
    TransformComponent = { get_property = function() end },
    Script = { world_created = function() end, world_destroyed = function() end },
    Unit = { alive = function() end, node = function() end, local_position = function() end },
    Matrix4x4 = {},
}
_G.CowboyBingusModLoader = { api = 1, version = 17, modules = {},
    -- Loader v18's JIT cache state.  The version above is deliberately 17: the v18 source
    -- still reports 17, which is exactly why the mods key off `jit.managed` instead.
    jit = { managed = true, expanded = true, watcher = true, flushes = 0, growths = 0,
            mcode_kb = 16384, traces = 8000 } }
if type(_G.update) ~= 'function' then _G.update = function(...) end end

-- ============================================================ driver helpers
function __set_ship_ticks(n) ship_remaining = n end

-- Remove an object, to model a session where only the sparse Hive Lord exists.
function __remove_goid(id)
    OBJ[id] = nil
    EXISTING[id] = nil
    return true
end

-- Damage the Hive Lord the way the wire actually does it: the six-bit synchronised
-- fraction falls and the damage mask loses a bit.  There is deliberately no absolute
-- health field to move, because the client does not have one -- moving one here is what
-- let the previous fixture certify a model the live data had already disproved.
function __damage(main, zone)
    local f = OBJ[31].fields
    local hp = math.floor(f[SYNC_IDX] * 63 + 0.5) / 63 * 150000 - (main or 0)
    local k = math.max(0, math.min(63, math.floor(hp / 150000 * 63 + 0.5)))
    f[SYNC_IDX] = k / 63
    if zone and zone > 0 and f[MASK_IDX] > 0 then f[MASK_IDX] = f[MASK_IDX] - 1 end
    return k
end
function __main_idx() return SYNC_IDX end
function __zone_idx() return MASK_IDX end
-- Set an arbitrary main health so the bar's clamping can be exercised.  Values above
-- the maximum cannot be represented by a six-bit fraction, so this clamps the fraction
-- to [0,1]; the renderer's own clamping is asserted through the pure seam instead.
function __set_main_health(v)
    local k = math.max(0, math.min(63, math.floor(v / 150000 * 63 + 0.5)))
    OBJ[31].fields[SYNC_IDX] = k / 63
    return k
end

-- Set any field of any object, to model damage landing on a watched candidate.
function __set_field(gid, idx, v)
    if not OBJ[gid] then return false end
    OBJ[gid].fields[idx] = v
    return true
end

-- Simulate a genuinely new session (a new peer), as opposed to the engine simply
-- returning a new wrapper for the same session.
function __session_change(peer)
    SESSION_PEER = peer or 'ffeeddccbbaa9988'
    return true
end

-- Leave / re-enter a session, which is how a real map change is now detected
-- (the handles' rendered values do not change across one).
function __set_in_session(v) IN_SESSION_OVERRIDE = v end

-- Minimal world: the only candidate holds nothing but 150000s.  A threshold that
-- demanded two *kinds* of known maximum would silently drop exactly this shape.
function __use_minimal_world()
    OBJ[31] = nil
    EXISTING[31] = nil
    obj(6000, { 0, 0, 150000, 150000, 0, 0 }, 'minimal')
    EXISTING[6000] = true
    return true
end

-- Sparse-id world, mirroring the live census which found objects at 4096 and 8192.
-- A Hive Lord at id 8192 is unreachable by walking 1..32766 at two ids per frame
-- within any reasonable test budget, so this is what distinguishes "probe the
-- census" from "walk the id space".
function __use_sparse_world()
    OBJ[31] = nil
    EXISTING[31] = nil
    obj(4096, { 1, 2, 3, 4, 5, 6 }, 'junk4096')
    obj(8192, hive_lord_fields(), 'un6y1d_hivelord')
    -- EXISTING is snapshotted at load time, so adding an object later must add it
    -- here too or game_object_exists will never report it.
    EXISTING[4096] = true
    EXISTING[8192] = true
    return true
end

function __gui_texts() return table.concat(__GUI_TEXTS, '|') end
-- Created-but-not-destroyed text handles.  This is the number that says whether the HUD
-- is manageable: 2 while a reading is shown, 0 once it is cleared.
function __gui_live_texts()
    local n = 0
    for _ in pairs(__GUI_LIVE) do n = n + 1 end
    return n
end
function __gui_destroy_ids() return table.concat(__GUI_DESTROY_IDS, ',') end
-- The text currently on screen, in handle order.  Empty means a blank HUD.
function __gui_live_text()
    local ids = {}
    for id in pairs(__GUI_LIVE) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = __GUI_TEXT_BY_ID[id] or '' end
    return table.concat(out, '|')
end
-- Drop every world so the surface's owner no longer exists (a mission change).
function __drop_gui_world() __GUI_WORLD_GONE = true return true end
function __gui_counts() return string.format('%d,%d', __GUI_CREATED, __GUI_DESTROYED) end
function __calls_reset() __CALLS = {} end
function __distinct_calls()
    local seen, out = {}, {}
    for _, c in ipairs(__CALLS) do if not seen[c] then seen[c] = true; out[#out + 1] = c end end
    table.sort(out)
    return table.concat(out, ',')
end
