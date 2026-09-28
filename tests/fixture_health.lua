-- Offline fixture for hivelord_health.
--
-- The game is replaced by a synthetic address space with the three things the addon
-- touches: the PE headers of game.dll and helldivers2.exe (the build gate), the health
-- manager, and the health table.  All offsets here are the REAL ones from Enemy HP 1.1.1,
-- because the point of the suite is to prove that code using those offsets reads the
-- structure they describe.
--
-- The health table slot for the Hive Lord's key is computed in Python with exact integer
-- arithmetic (key % 1002 = 981) rather than with the addon's own formula, so a wrong slot
-- calculation cannot agree with the fixture by construction.

local real_os = os
local REGIONS = {}

local function blank(n) return string.rep('\0', n) end

local function from_hex(h)
    local out = {}
    for i = 1, #h, 2 do out[#out + 1] = string.char(tonumber(h:sub(i, i + 1), 16)) end
    return table.concat(out)
end

local function put_u32(s, off, v)
    local b = {}
    for i = 0, 3 do b[#b + 1] = string.char(math.floor(v / 2 ^ (8 * i)) % 256) end
    return s:sub(1, off) .. table.concat(b) .. s:sub(off + 5)
end

local function put_u64(s, off, v)
    local lo = v % 4294967296
    local hi = math.floor(v / 4294967296)
    return put_u32(put_u32(s, off, lo), off + 4, hi)
end

local function put_i32(s, off, v)
    if v < 0 then v = v + 4294967296 end
    return put_u32(s, off, v)
end

local function add_region(base, data) REGIONS[#REGIONS + 1] = { base = base, data = data } end

local function region_of(addr)
    for _, r in ipairs(REGIONS) do
        if addr >= r.base and addr < r.base + #r.data then return r, addr - r.base end
    end
    return nil, nil
end

-- ============================================================ the two modules
local GAME_TS, GAME_SIZE, GAME_SUM = 0x6AB3B43F, 0x4744000, 0xECDA6F
local EXE_TS, EXE_SIZE, EXE_SUM = 0x6AB382E4, 0x39E8000, 0xE48B1D

local function make_pe(ts, size, sum)
    local s = blank(0x1000)
    s = 'MZ' .. s:sub(3)
    s = put_u32(s, 0x3C, 0x80)
    s = s:sub(1, 0x80) .. 'PE\0\0' .. s:sub(0x85)
    s = put_u32(s, 0x80 + 8, ts)
    s = put_u32(s, 0x80 + 24 + 56, size)
    s = put_u32(s, 0x80 + 24 + 64, sum)
    return s
end

local GAME_BASE = 0x140000000
local EXE_BASE = 0x7FF00000000
local IMG = 0x4000000            -- 64 MB: covers 0x3326688 and 0x346BF98

-- ==================================================== the health manager
local HM = 0x20000000
local ARR = 0x21000000
local RECS = 0x22000000
local DESCS = 0x23000000
local NET = 0x24000000
local TBL = 0x25000000
local HM_SHIP = 0x26000000
local ARR_SHIP = 0x26100000
local RECS_SHIP = 0x26200000
local DESCS_SHIP = 0x26300000
local MAT_REGION = 0x27000000

local N_ENTRIES = 6
local HIVE_J = 3
local HIVE_CUR = 145238
local HIVE_MAX = 150000
local HIVE_KEY_HEX = 'cb077af7c7d965d4'   -- little-endian key, exactly as the reader has it
local TABLE_IDX = 7
local TABLE_SLOT = 981                     -- key % 1002, computed in Python
local OTHER_TYPE = '0807060504030201'

local function install()
    local img = make_pe(GAME_TS, GAME_SIZE, GAME_SUM) .. blank(IMG - 0x1000)
    img = put_u64(img, 0x3326688, HM)
    img = put_u64(img, 0x346BF98, NET)
    add_region(GAME_BASE, img)
    add_region(EXE_BASE, make_pe(EXE_TS, EXE_SIZE, EXE_SUM))

    local db = blank(N_ENTRIES * 24)
    for j = 0, N_ENTRIES - 1 do
        local off = j * 24
        db = db:sub(1, off) .. from_hex(OTHER_TYPE) .. db:sub(off + 9)
        db = put_u32(db, off + 8, 1000 + j)
        db = put_u32(db, off + 12, 2000 + j)
        db = put_u32(db, off + 16, 3000 + j)
        db = put_u32(db, off + 20, 0)
    end
    db = db:sub(1, HIVE_J * 24) .. from_hex(HIVE_KEY_HEX) .. db:sub(HIVE_J * 24 + 9)
    add_region(DESCS, db)

    local arr = blank(N_ENTRIES * 8)
    for j = 0, N_ENTRIES - 1 do arr = put_u64(arr, j * 8, DESCS + j * 24) end
    add_region(ARR, arr)

    local recs = blank(N_ENTRIES * 0x1B8)
    for j = 0, N_ENTRIES - 1 do recs = put_i32(recs, j * 0x1B8 + 0x14, 5000 + j) end
    recs = put_i32(recs, HIVE_J * 0x1B8 + 0x14, HIVE_CUR)
    add_region(RECS, recs)

    local hm = blank(0x1100)
    hm = put_u32(hm, 0x1020, N_ENTRIES)
    hm = put_u64(hm, 0x1048, ARR)
    hm = put_u64(hm, 0x1058, RECS)
    add_region(HM, hm)

    -- The network root is a large structure: the health table pointer lives at +0xF12B78,
    -- so a small region here would make the lookup fail for the wrong reason.
    local net = blank(0xF12B78 + 0x10)
    net = put_u64(net, 0xF12B78, TBL)
    add_region(NET, net)

    local tbl = blank(0x30000)
    tbl = tbl:sub(1, TABLE_SLOT * 16) .. from_hex(HIVE_KEY_HEX) .. tbl:sub(TABLE_SLOT * 16 + 9)
    tbl = put_u32(tbl, TABLE_SLOT * 16 + 8, TABLE_IDX)
    tbl = put_u32(tbl, 0x3EA0 + TABLE_IDX * 0x5650, HIVE_MAX)
    add_region(TBL, tbl)

    -- The font / alpha / material ids the shipped Enemy HP mod reads out of the game.  A
    -- Gui.text call with a font the engine cannot resolve is still accepted and renders
    -- nothing, so these globals are part of the drawing path and the fixture has to carry
    -- them: with them absent, a mod that passes a debug-font STRING looks identical to one
    -- that passes the real ids.
    img = img:sub(1, 0x3772268) .. from_hex('8877665544332211') .. img:sub(0x3772268 + 9)
    img = img:sub(1, 0x3772EE8) .. from_hex('aa550000aa550000') .. img:sub(0x3772EE8 + 9)
    img = put_u64(img, 0x37C5478, MAT_REGION)
    -- (rewritten into the region table below; the image was built before this point)
    REGIONS[1].data = img
    local mat = blank(0x40)
    mat = mat:sub(1, 24) .. from_hex('ffeeddccbbaa9988') .. mat:sub(33)
    add_region(MAT_REGION, mat)

    -- A second manager, as the ship has: ONE entry, and not the Hive Lord.  It has to be
    -- readable for the caching bug to show: an EMPTY manager is never cached (the read
    -- returns before that), which is itself a state worth reporting and is exercised
    -- separately by setting the count to 0.  The game re-points the manager global when the
    -- world changes, so an addon that caches a readable manager keeps reading the ship's
    -- one inside the mission -- which is what a live session did for eleven minutes while
    -- the Hive Lord was being damaged.
    local sarr = blank(8)
    sarr = put_u64(sarr, 0, DESCS_SHIP)
    add_region(ARR_SHIP, sarr)
    local srec = blank(0x1B8)
    srec = put_i32(srec, 0x14, 4321)
    add_region(RECS_SHIP, srec)
    local sdesc = blank(24)
    sdesc = sdesc:sub(1, 1) .. from_hex(OTHER_TYPE) .. sdesc:sub(9)
    sdesc = put_u32(sdesc, 8, 77)
    sdesc = put_u32(sdesc, 12, 88)
    sdesc = put_u32(sdesc, 16, 99)
    add_region(DESCS_SHIP, sdesc)
    local ship = blank(0x1100)
    ship = put_u32(ship, 0x1020, 1)
    ship = put_u64(ship, 0x1048, ARR_SHIP)
    ship = put_u64(ship, 0x1058, RECS_SHIP)
    add_region(HM_SHIP, ship)
end
install()

-- ============================================================== fake ffi
-- KERNEL is declared first: `ffi.load` refers to it, and a reference before the `local`
-- would resolve to a global that is nil at call time.
local KERNEL = {}
local ffi = {}
function ffi.abi(what) if what == '64bit' then return true end return false end
function ffi.cdef(_) end
function ffi.load(_) return KERNEL end

local function buf_new(n) return { __buf = blank(n), __size = n } end

function ffi.new(ctype, a)
    if ctype == 'size_t[1]' then return { [0] = 0 } end
    if type(ctype) == 'string' and ctype:match('^uint8_t%[%?%]$') then return buf_new(a) end
    if type(ctype) == 'string' and ctype:match('^uint8_t%[%d+%]$') then
        return buf_new(tonumber(ctype:match('%[(%d+)%]')))
    end
    error('ffi.new: unsupported ctype ' .. tostring(ctype))
end

function ffi.string(buf, len)
    if type(buf) ~= 'table' or not buf.__buf then error('ffi.string: not a buffer') end
    return buf.__buf:sub(1, len or buf.__size)
end

function ffi.cast(ctype, v)
    if ctype == 'uintptr_t' then
        if type(v) == 'number' then return v end
        if type(v) == 'table' and v.__ptr then return v.__ptr end
        error('ffi.cast(uintptr_t): bad value')
    elseif ctype == 'void *' or ctype == 'const void *' then
        if type(v) ~= 'number' then error('ffi.cast(void *): expected a number') end
        return { __ptr = v }
    end
    error('ffi.cast: unsupported ctype ' .. tostring(ctype))
end

function KERNEL.GetCurrentProcess() return { __ptr = 1 } end
function KERNEL.GetModuleHandleA(name)
    if rawget(_G, '__MODULE_HIDDEN') then return nil end
    if name == 'game.dll' then return { __ptr = GAME_BASE } end
    if name == 'helldivers2.exe' then return { __ptr = EXE_BASE } end
    return nil
end

function KERNEL.ReadProcessMemory(process, address, buffer, size, got)
    if type(process) ~= 'table' or not process.__ptr then
        error('ReadProcessMemory: process handle must be a pointer')
    end
    if type(address) ~= 'table' or not address.__ptr then
        error('ReadProcessMemory: address must be a pointer (raw numbers are a bug)')
    end
    local r, off = region_of(address.__ptr)
    if not r or off + size > #r.data then
        __READ_ERRORS = __READ_ERRORS + 1
        got[0] = 0
        return 0
    end
    buffer.__buf = r.data:sub(off + 1, off + size)
    got[0] = size
    __READS = __READS + 1
    return 1
end

function KERNEL.VirtualQuery(addr, info, len)
    local a = (type(addr) == 'table' and addr.__ptr) or addr
    info.BaseAddress, info.AllocationBase = a, 0
    info.RegionSize, info.State, info.Protect = 0x1000, 0x10000, 0x01
    return 48
end

_G.__READS, _G.__READ_ERRORS = 0, 0
_G.ffi = ffi
require = function(name) if name == 'ffi' then return ffi end error('no module ' .. name) end

-- ============================================================== environment
local APPDATA = os.getenv('HIVELORD_TEST_APPDATA')
os = {
    getenv = function(name) if name == 'APPDATA' then return APPDATA end return nil end,
    clock = real_os.clock, time = real_os.time, date = real_os.date,
    remove = real_os.remove, rename = real_os.rename,
}

-- ============================================================== the game API
local GUI_TEXTS, GUI_LIVE, GUI_TEXT_BY_ID = {}, {}, {}
local GUI_NEXT, GUI_CREATED, GUI_DESTROYED = 0, 0, 0
local GUI_UPDATES, GUI_DESTROYS, GUI_WORLD_DESTROYS = 0, 0, 0
local WORLD_N = 0
local GUI_FONTS, GUI_MATS, GUI_POS = {}, {}, {}

local function handle(render)
    return setmetatable({}, { __tostring = function() return render end })
end

local IdString64 = {}
function IdString64.from_hex(h)
    return setmetatable({ hex = h },
        { __tostring = function(self) return 'IdString64(' .. tostring(self.hex) .. ')' end })
end

-- The material API the reference configures before any text uses it.  A Gui.text call whose
-- material was never configured is a native fault in the engine, not a Lua error, so the
-- fixture has to be able to both provide this API and take it away.
local MATERIAL_CALLS = {}
local Mat = {}
Mat.set_scalar = function() MATERIAL_CALLS[#MATERIAL_CALLS + 1] = 'scalar' return true end
Mat.set_vector2 = function() MATERIAL_CALLS[#MATERIAL_CALLS + 1] = 'vector2' return true end
Mat.set_vector4 = function() MATERIAL_CALLS[#MATERIAL_CALLS + 1] = 'vector4' return true end
Mat.set_texture = function() MATERIAL_CALLS[#MATERIAL_CALLS + 1] = 'texture' return true end

local Gui = {}
Gui.resolution = function() return 1920, 1080 end
Gui.material = function(gui, id)
    MATERIAL_CALLS[#MATERIAL_CALLS + 1] = 'material'
    return { ink = true, id = id }
end
Gui.text = function(gui, s, font, size, font2, pos, col)
    GUI_TEXTS[#GUI_TEXTS + 1] = tostring(s)
    GUI_FONTS[#GUI_FONTS + 1] = tostring(font)
    GUI_MATS[#GUI_MATS + 1] = tostring(font2)
    -- Only the components that are actually present: the proven call passes a Vector2, the
    -- reference's path passed a Vector3, and a recorder that assumes three would silently
    -- report "x,y,nil" as a 3-component position.
    local function pos_text(p)
        if not p then return 'nil' end
        if p.z ~= nil then return tostring(p.x) .. ',' .. tostring(p.y) .. ',' .. tostring(p.z) end
        return tostring(p.x) .. ',' .. tostring(p.y)
    end
    GUI_POS[#GUI_POS + 1] = pos_text(pos)
    GUI_NEXT = GUI_NEXT + 1
    GUI_LIVE[GUI_NEXT] = true
    GUI_TEXT_BY_ID[GUI_NEXT] = tostring(s)
    return GUI_NEXT
end
Gui.destroy_text = function(gui, id)
    if id == nil then error('Gui.destroy_text: called without a handle') end
    GUI_DESTROYS = GUI_DESTROYS + 1
    GUI_LIVE[id] = nil
    GUI_TEXT_BY_ID[id] = nil
    GUI_DESTROYED = GUI_DESTROYED + 1
    return true
end
-- Updating in place is what the reference does instead of destroy-and-recreate.
Gui.update_text = function(gui, id, s, font, size, mat, pos, col)
    GUI_UPDATES = GUI_UPDATES + 1
    if id ~= nil then GUI_TEXT_BY_ID[id] = tostring(s) end
    return true
end
Gui.destroy_triangle = function() return true end

local World = {}
World.create_screen_gui = function() GUI_CREATED = GUI_CREATED + 1 return { gui = true } end
-- Counted, not just accepted: destroying a surface is the call that took the game down on
-- mission entry, so "it is never called" is a property the suite asserts.
World.destroy_gui = function()
    GUI_WORLD_DESTROYS = GUI_WORLD_DESTROYS + 1
    return true
end

local App = {}
App.worlds = function()
    if rawget(_G, '__NO_WORLDS') then return {} end
    if rawget(_G, '__ONE_WORLD') then return { handle('[World]') } end
    -- Every world renders the same string, as a live log showed (11 worlds, none
    -- distinguishable by rendering), so the identity branch is the one that has to pick.
    if rawget(_G, '__SAME_RENDER') then
        return { handle('[World]'), handle('[World]'), handle('[World]') }
    end
    if rawget(_G, '__WORLD_CHURN') then
        -- BOTH elements get a fresh render string, so whichever one is picked its key is gone
        -- by the next call and an uncapped version would make a surface on every frame.
        WORLD_N = WORLD_N + 1
        return { handle('[World-' .. WORLD_N .. ']'),
                 handle('[UIWorld-' .. WORLD_N .. ']') }
    end
    if rawget(_G, '__NEW_WORLD') then return { handle('[World]'), handle('[UIWorld-2]') } end
    return { handle('[World]'), handle('[UIWorld]') }
end
App.main_world = function() return handle('[World]') end

_G.stingray = {
    Application = App, World = World, Gui = Gui, IdString64 = IdString64, Material = Mat,
    Vector2 = function(x, y) return { x = x, y = y } end,
    Vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
    Color = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
}
if rawget(_G, '__NO_MATERIAL_API') then _G.stingray.Material = nil end
if rawget(_G, '__NO_IDS') then _G.stingray.IdString64 = nil end
_G.CowboyBingusModLoader = { api = 1, version = 17, modules = {} }
if type(_G.update) ~= 'function' then _G.update = function(...) end end

-- ============================================================== driver helpers
function __set_build(field, value)
    local which = rawget(_G, '__BUILD_TARGET') or 'game'
    local base = which == 'game' and GAME_BASE or EXE_BASE
    local r = region_of(base)
    local off = 0x80 + (field == 1 and 8 or (field == 2 and 80 or 88))
    r.data = put_u32(r.data, off, value)
    return true
end
-- Zero the alpha texture id, as an unreadable or not-yet-populated global would be.  The
-- reference refuses to draw without it; treating it as optional hands the engine a material
-- whose texture was never set, which is a native fault.
function __zero_alpha()
    local r = region_of(GAME_BASE)
    r.data = r.data:sub(1, 0x3772EE8) .. from_hex('0000000000000000')
        .. r.data:sub(0x3772EE8 + 9)
    return true
end

function __break_build() return __set_build(1, 0x11111111) end
function __restore_build()
    local r = region_of(GAME_BASE)
    r.data = put_u32(r.data, 0x80 + 8, GAME_TS)
    r.data = put_u32(r.data, 0x80 + 80, GAME_SIZE)
    r.data = put_u32(r.data, 0x80 + 88, GAME_SUM)
    local e = region_of(EXE_BASE)
    e.data = put_u32(e.data, 0x80 + 8, EXE_TS)
    e.data = put_u32(e.data, 0x80 + 80, EXE_SIZE)
    e.data = put_u32(e.data, 0x80 + 88, EXE_SUM)
    return true
end
function __set_hp(j, v)
    local r = region_of(RECS)
    r.data = put_i32(r.data, j * 0x1B8 + 0x14, v)
    return true
end
-- Replace the Hive Lord's descriptor key with another type, so the manager no longer holds
-- an entry for it.  This is how "the reader cannot find its entry" is distinguished from
-- "the manager itself is unreadable".
function __break_key()
    local r = region_of(DESCS)
    r.data = r.data:sub(1, HIVE_J * 24) .. from_hex(OTHER_TYPE) .. r.data:sub(HIVE_J * 24 + 9)
    return true
end
function __set_manager_count(n)
    local r = region_of(HM)
    r.data = put_u32(r.data, 0x1020, n)
    return true
end
-- Point the manager global at the ship's manager, as the game does before a mission.
function __use_ship_manager()
    local img = region_of(GAME_BASE)
    img.data = put_u64(img.data, 0x3326688, HM_SHIP)
    return true
end
-- ...and back at the mission's, as the game does when the world changes.
function __use_mission_manager()
    local img = region_of(GAME_BASE)
    img.data = put_u64(img.data, 0x3326688, HM)
    return true
end
function __hive_j() return HIVE_J end
function __hive_cur() return HIVE_CUR end
function __entries() return N_ENTRIES end
function __reads() return __READS end
function __read_errors() return __READ_ERRORS end
function __gui_texts() return table.concat(GUI_TEXTS, '|') end
function __material_calls() return table.concat(MATERIAL_CALLS, ',') end
function __gui_fonts() return table.concat(GUI_FONTS, '|') end
function __gui_mats() return table.concat(GUI_MATS, '|') end
function __gui_pos() return table.concat(GUI_POS, '|') end
function __gui_created() return GUI_CREATED end
function __gui_destroyed() return GUI_DESTROYED end
-- Text objects created (Gui.text calls) versus updated in place.  The create count is the
-- number that decides whether the addon can exhaust the engine's GUI resources.
function __gui_text_creates() return GUI_NEXT end
function __gui_updates() return GUI_UPDATES end
function __gui_destroys() return GUI_DESTROYS end
function __world_destroys() return GUI_WORLD_DESTROYS end
function __gui_live_text()
    local ids = {}
    for id in pairs(GUI_LIVE) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = GUI_TEXT_BY_ID[id] or '' end
    return table.concat(out, '|')
end
function __gui_live_count()
    local n = 0
    for _ in pairs(GUI_LIVE) do n = n + 1 end
    return n
end
return true
