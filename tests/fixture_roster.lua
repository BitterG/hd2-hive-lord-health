-- Test double for hivelord_roster.lua.
--
-- The roster reader is pointer arithmetic over a handful of small blocks, so the fixture
-- is a synthetic address space laid out exactly like the documented one:
--
--   module image  : game.dll base, with the build-gate bytes and the director pointer
--   director      : three 8-byte faction slots
--   roster header : +0x00 rows pointer, +0x08 count
--   rows          : count * 0x80, entity id at row+8
--
-- The stub is deliberately type-strict: a bare number where a pointer is required
-- raises, the same way real FFI does.  os.clock stays real because the addon budgets on
-- it, and os.remove/os.rename stay real so the staged STATUS write is exercised rather
-- than silently downgraded.

_G.__READS = {}
_G.__READ_ERRORS = 0

local real_os = os
local TEST_APPDATA = real_os.getenv('HIVELORD_TEST_APPDATA')
os = {
    getenv = function(name) if name == 'APPDATA' then return TEST_APPDATA end return nil end,
    clock = real_os.clock,
    time = real_os.time,
    date = real_os.date,
    remove = real_os.remove,
    rename = real_os.rename,
}

-- ============================================================= fake memory
local MODULE_BASE = 0x140000000
local DIRECTOR = 0x20000000
local HDR_A = 0x30000000
local HDR_B = 0x30001000
local HDR_C = 0x30002000
local ROWS_A = 0x40000000
local ROWS_B = 0x40010000
local ROWS_C = 0x40020000

local SLOT_A, SLOT_B, SLOT_C = 0x660, 0x668, 0x670

local ROW_STRIDE = 0x80

local function blank(n) return string.rep('\0', n) end

local function place(s, off, block)
    return s:sub(1, off) .. block .. s:sub(off + #block + 1)
end

local function put_i32(s, off, v)
    local b = { v % 256, math.floor(v / 256) % 256,
                math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 }
    for i = 1, 4 do
        s = s:sub(1, off + i - 1) .. string.char(b[i]) .. s:sub(off + i + 1)
    end
    return s
end

-- A 64-bit pointer, written as two u32 halves (never as one Lua number).
local function put_u64(s, off, v)
    local lo = v % 4294967296
    local hi = math.floor(v / 4294967296)
    s = put_i32(s, off, lo)
    s = put_i32(s, off + 4, hi)
    return s
end

local function from_hex(h)
    return (h:gsub('%x%x', function(p) return string.char(tonumber(p, 16)) end))
end

local REGIONS = {}
local function add_region(base, data) REGIONS[#REGIONS + 1] = { base = base, data = data } end
local function region(base) 
    for i, r in ipairs(REGIONS) do if r.base == base then return REGIONS[i] end end
    return nil
end

-- module image: gate signature + director pointer
local img = blank(0x276CA30)
img = place(img, 0x93F159, from_hex('498b4008'))
img = put_u64(img, 0x276CA20, DIRECTOR)
add_region(MODULE_BASE, img)

-- director: three faction slots
local dirn = blank(0x700)
dirn = put_u64(dirn, SLOT_A, HDR_A)
dirn = put_u64(dirn, SLOT_B, HDR_B)
dirn = put_u64(dirn, SLOT_C, HDR_C)
add_region(DIRECTOR, dirn)

-- roster headers
for _, h in ipairs({ { HDR_A, ROWS_A }, { HDR_B, ROWS_B }, { HDR_C, ROWS_C } }) do
    local hdr = blank(0xB0)
    hdr = put_u64(hdr, 0, h[2])
    hdr = put_i32(hdr, 8, 0)
    add_region(h[1], hdr)
end

-- The captured Terminid roster: 44 rows, the Hive Lord at row 35 (0-based 34) exactly as
-- All-Stalker's live capture has it.  Row indices matter to the tests.
local CAPTURE = {
    { '4e7e99f66ba8ee51', 0 }, { '0c237b28ae3a8a9a', 0 }, { '3ddbd6ce493ea872', 0 },
    { 'd98f5e6f5938b4aa', 0 }, { 'b96be4a113e339be', 0 }, { 'dc9c7cecc41f5432', 0 },
    { 'e4bd0fa4f27bf3a1', 0 }, { 'e4bd0fa4f27bf3a1', 0 }, { 'f63e16f6ce1a0810', 0 },
    { 'e4bd0fa4f27bf3a1', 0 }, { 'cae174d5e2030e3d', 0 }, { 'bac045744432a85c', 0 },
    { 'a543d44847fd22d5', 0 }, { 'b064c698ffcd7f1a', 0 }, { '4cacb367ecd15ba0', 0 },
    { '4601e6e5cc99aa36', 0 }, { 'b791d5ac6452aecc', 0 }, { 'ddafccccf2172e9e', 0 },
    { '2e424a9d9dca40f5', 0 }, { 'dc48a977d9cbbadf', 0 }, { '4b7adc3b07fb974e', 0 },
    { '9b0872d1fd2270cc', 0 }, { 'dc9c7cecc41f5432', 0 }, { 'e4bd0fa4f27bf3a1', 0 },
    { '990b45d5d75fff3a', 0 }, { 'dd35245088000964', 0 }, { '883d333823e22160', 0 },
    { 'b96be4a113e339be', 0 }, { '3beefb1242e7f8dc', 0 }, { '4aa33b7fa17d2f67', 0 },
    { 'df974365bbd89cf7', 0 }, { 'e6c784421efaa6b2', 0 }, { '5e60abf49223206b', 0 },
    { '525a2df2ba90e9d1', 0 }, { 'cb077af7c7d965d4', 0 },   -- <-- the Hive Lord
    { 'aafaa321a4480b96', 0 }, { '94ebd3071ca181a3', 0 }, { '060815f2c60752a3', 0 },
    { '8c221c132bb9b70a', 0 }, { '97a497d084cb04ef', 0 }, { 'bc0e441d35218472', 0 },
    { 'e004009c72910a1f', 0 }, { '01f51cbe314696db', 0 }, { '0378893c654752fd', 0 },
}

local HIVE_ROW_INDEX = 35   -- 1-based; the conclusion reports this

local function rows_blob(entities)
    local s = blank(#entities * ROW_STRIDE)
    for i, e in ipairs(entities) do
        local off = (i - 1) * ROW_STRIDE + 8
        s = place(s, off, from_hex(e))
    end
    return s
end

-- slot A holds the captured Terminid roster; slots B and C are empty by default.
add_region(ROWS_A, rows_blob({}))
for _, e in ipairs(CAPTURE) do end
local capture_entities = {}
for i, e in ipairs(CAPTURE) do capture_entities[i] = e[1] end
add_region(ROWS_A, rows_blob(capture_entities))
add_region(ROWS_B, blank(16 * ROW_STRIDE))
add_region(ROWS_C, blank(16 * ROW_STRIDE))

local function set_count(header, n)
    local r = region(header)
    r.data = put_i32(r.data, 8, n)
end
set_count(HDR_A, #capture_entities)
set_count(HDR_B, 0)
set_count(HDR_C, 0)

local function region_of(addr)
    for _, r in ipairs(REGIONS) do
        if addr >= r.base and addr < r.base + #r.data then return r, addr - r.base end
    end
    return nil, nil
end

-- ========================================== fake health manager and its accessor
-- Enemy HP 1.1.1's layout:
--   hm = *(game + RVA); n = u32 AT hm+0x1020; arr = *(hm+0x1048); recs = *(hm+0x1058)
--   descriptor d = *(arr + j*8) = [u64 type][u32 entity][u32 unit][u32 goid][u32 flags]
--   current HP   = i32 at recs + j*0x1B8 + 0x14
local HM_GLOBAL = MODULE_BASE + 0x1000    -- the data global holding the manager pointer
local HM = 0x21000000
local ARR = 0x22000000
local RECS = 0x23000000
local DESCS = 0x24000000
local N_ENTRIES = 6
local HIVE_J = 3                          -- 0-based entry index
local HIVE_CUR = 145238

local dblob = blank(N_ENTRIES * 24)
for j = 0, N_ENTRIES - 1 do
    local off = j * 24
    dblob = place(dblob, off, from_hex('0102030405060708'))  -- a type we do not care about
    dblob = put_i32(dblob, off + 8, 1000 + j)                -- entity
    dblob = put_i32(dblob, off + 12, 2000 + j)               -- unit
    dblob = put_i32(dblob, off + 16, 3000 + j)               -- goid
    dblob = put_i32(dblob, off + 20, 0)                      -- flags
end
dblob = place(dblob, HIVE_J * 24, from_hex('cb077af7c7d965d4'))
add_region(DESCS, dblob)

local arr = blank(N_ENTRIES * 8)
for j = 0, N_ENTRIES - 1 do arr = put_u64(arr, j * 8, DESCS + j * 24) end
add_region(ARR, arr)

local recs = blank(N_ENTRIES * 0x1B8)
for j = 0, N_ENTRIES - 1 do recs = put_i32(recs, j * 0x1B8 + 0x14, 5000 + j) end
recs = put_i32(recs, HIVE_J * 0x1B8 + 0x14, HIVE_CUR)
add_region(RECS, recs)

local hm = blank(0x1100)
hm = put_i32(hm, 0x1020, N_ENTRIES)
hm = put_u64(hm, 0x1048, ARR)
hm = put_u64(hm, 0x1058, RECS)
add_region(HM, hm)

-- The accessor, placed low in the image so the first scan chunk reaches it:
--   +0x800: mov rcx,[rip+disp32]  -> the manager global
--   +0x840: mov rdx,[rcx+0x1048]
--   +0x850: mov rdx,[rcx+0x1058]
local CODE_OFF = 0x800
local function install_code()
    local img = region(MODULE_BASE)
    local insn_va = MODULE_BASE + CODE_OFF
    img.data = place(img.data, CODE_OFF, from_hex('488b0d'))
    img.data = put_i32(img.data, CODE_OFF + 3, HM_GLOBAL - (insn_va + 7))
    img.data = place(img.data, CODE_OFF + 0x40, from_hex('488b9148100000'))
    img.data = place(img.data, CODE_OFF + 0x50, from_hex('488b9158100000'))
    img.data = put_u64(img.data, HM_GLOBAL - MODULE_BASE, HM)
end
install_code()

-- ============================================================= fake ffi
local ffi = {}
function ffi.abi(what) if what == '64bit' then return true end return false end
function ffi.cdef(_) end

local function buf_new(n) return { __buf = blank(n), __size = n } end

function ffi.new(ctype, a)
    if ctype == 'size_t[1]' then return { [0] = 0 } end
    if ctype == 'HL_ROSTER_MBI' then
        return { BaseAddress = 0, AllocationBase = 0, RegionSize = 0, State = 0, Protect = 0 }
    end
    if type(ctype) == 'string' and ctype:match('^uint8_t%[%?%]$') then return buf_new(a) end
    if type(ctype) == 'string' and ctype:match('^uint8_t%[%d+%]$') then
        return buf_new(tonumber(ctype:match('%[(%d+)%]')))
    end
    error('ffi.new: unsupported ctype ' .. tostring(ctype))
end

function ffi.sizeof(x)
    if x == nil then return 48 end
    if type(x) == 'table' and x.__size then return x.__size end
    return 48
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
        -- Type-strict on purpose: a bare number here is the exact mistake real FFI
        -- rejects, and the fixture must reject it too or the suite proves nothing.
        if type(v) ~= 'number' then error('ffi.cast(void *): expected a number') end
        return { __ptr = v }
    end
    error('ffi.cast: unsupported ctype ' .. tostring(ctype))
end

local KERNEL = {}
function KERNEL.GetCurrentProcess() return { __ptr = 1 } end
function KERNEL.GetModuleHandleA(name)
    if rawget(_G, '__MODULE_HIDDEN') then return nil end
    if name == 'game.dll' then return { __ptr = MODULE_BASE } end
    return nil
end

-- One executable, committed region: the module image.  Anything else reports free
-- memory, so the loader's region walk stops after the image instead of running on.
function KERNEL.VirtualQuery(addr, info, len)
    local a = (type(addr) == 'table' and addr.__ptr) or addr
    if type(a) ~= 'number' then error('VirtualQuery: address must be a pointer') end
    local img = region(MODULE_BASE)
    if a >= MODULE_BASE and a < MODULE_BASE + #img.data then
        info.BaseAddress = MODULE_BASE
        info.AllocationBase = MODULE_BASE
        info.RegionSize = #img.data
        info.State = 0x1000          -- MEM_COMMIT
        info.Protect = 0x20          -- PAGE_EXECUTE_READ
        return 48
    end
    info.BaseAddress = a
    info.AllocationBase = 0
    info.RegionSize = 0x1000
    info.State = 0x10000             -- MEM_FREE
    info.Protect = 0x01              -- PAGE_NOACCESS
    return 48
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
    __READS[#__READS + 1] = string.format('read 0x%x %d', address.__ptr, size)
    return 1
end

function ffi.load(name)
    if name ~= 'kernel32' then error('ffi.load: only kernel32 is stubbed') end
    return KERNEL
end

_G.ffi = ffi

local real_require = require
_G.require = function(name)
    if name == 'ffi' then return ffi end
    if real_require then return real_require(name) end
    error('module not found: ' .. tostring(name))
end

-- Loader v18 / API 1.  `version` is deliberately 17, because the v18 source still reports
-- 17 -- the JIT cache state is the reliable signal, not the version number.
_G.CowboyBingusModLoader = { api = 1, version = 17, modules = {},
    jit = { managed = true, expanded = true, watcher = true, flushes = 0, growths = 0,
            mcode_kb = 16384, traces = 8000 } }

if type(_G.update) ~= 'function' then _G.update = function(...) end end

-- ============================================================ driver helpers
function __module(name)
    if name == 'game.dll' then return MODULE_BASE end
    return nil
end

-- Make the director pointer unreadable, to model "not in a mission yet".
function __clear_director()
    local r = region(MODULE_BASE)
    r.data = put_u64(r.data, 0x276CA20, 0)
    return true
end
function __set_director(addr)
    local r = region(MODULE_BASE)
    r.data = put_u64(r.data, 0x276CA20, addr or DIRECTOR)
    return true
end

-- Corrupt the build-gate signature.
function __break_gate()
    local r = region(MODULE_BASE)
    r.data = place(r.data, 0x93F159, from_hex('90909090'))
    return true
end
function __fix_gate()
    local r = region(MODULE_BASE)
    r.data = place(r.data, 0x93F159, from_hex('498b4008'))
    return true
end

function __set_slot(slot, header)
    local r = region(DIRECTOR)
    r.data = put_u64(r.data, slot, header or 0)
    return true
end

-- Give a slot a roster of `entities` (a list of little-endian hex ids).
function __set_roster(header, rows_base, entities)
    local r = region(header)
    r.data = put_u64(r.data, 0, rows_base)
    r.data = put_i32(r.data, 8, #entities)
    local rr = region(rows_base)
    rr.data = rows_blob(entities)
    return true
end

-- An implausible count, to prove the bound is checked before any read.
function __set_count(header, n)
    local r = region(header)
    r.data = put_i32(r.data, 8, n)
    return true
end

function __hive_lord_hex() return 'cb077af7c7d965d4' end

-- Rewrite slot A's roster with the Hive Lord removed, keeping every other row.  Building
-- the list here rather than in the harness matters: a Python list handed to Lua arrives
-- as a POBJECT, not a table, and the fixture must not hide that.
function __drop_hive_lord()
    local keep = {}
    for _, e in ipairs(capture_entities) do
        if e ~= 'cb077af7c7d965d4' then keep[#keep + 1] = e end
    end
    local r = region(ROWS_A)
    r.data = rows_blob(keep)
    set_count(HDR_A, #keep)
    return #keep
end
function __capture_entities()
    local t = {}
    for i, e in ipairs(CAPTURE) do t[i] = e[1] end
    return table.concat(t, ',')
end
function __hive_row_index() return HIVE_ROW_INDEX end

function __reads_count() return #__READS end
function __read_errors() return __READ_ERRORS end

-- ============================================== health-manager driver helpers
-- Raw code bytes, deliberately returned as a Lua string: the harness must not let it
-- cross into Python (lupa decodes Lua strings as UTF-8 and would raise).
function __code_blob()
    local img = region(MODULE_BASE)
    return img.data:sub(CODE_OFF + 1, CODE_OFF + 0x80)
end
function __code_offset() return CODE_OFF end
function __code_va() return MODULE_BASE + CODE_OFF end

function __hp_entries() return N_ENTRIES end
function __hp_hive_j() return HIVE_J end
function __hp_hive_value() return HIVE_CUR end
function __hm_global() return HM end
-- The address of the data global that HOLDS the manager pointer.  The code scan must
-- recover this address, not the manager's own address.
function __hm_global_addr() return HM_GLOBAL end

function __set_hp(j, v)
    local r = region(RECS)
    r.data = put_i32(r.data, j * 0x1B8 + 0x14, v)
    return true
end

function __set_desc_type(j, hex)
    local r = region(DESCS)
    r.data = place(r.data, j * 24, from_hex(hex))
    return true
end

function __break_manager()
    local r = region(HM)
    r.data = put_i32(r.data, 0x1020, 100000)   -- implausible count
    return true
end

function __fix_manager()
    local r = region(HM)
    r.data = put_i32(r.data, 0x1020, N_ENTRIES)
    return true
end

-- Remove the accessor bytes, so no candidate global can be recovered at all.
function __remove_code()
    local img = region(MODULE_BASE)
    img.data = place(img.data, CODE_OFF, blank(0x60))
    return true
end

function __restore_code()
    install_code()
    return true
end
