-- Test double for the Win32/FFI surface used by hivelord_memscan.lua.
--
-- The stub is deliberately type-strict: passing a bare number where a pointer is
-- required raises, the same way real FFI does.  The fake address space is built
-- from real struct offsets so the scanner's own arithmetic is what is under test.

_G.__READS = {}
_G.__READ_ERRORS = 0
_G.__BIG_READS = 0
_G.__EXTRA_ALLOC = nil

-- Shadow os so the addon's config/log paths land in a temp dir, exactly like the
-- primary probe fixture.  os.clock stays real because the scanner budgets on it.
local real_os = os
local TEST_APPDATA = os.getenv('HIVELORD_TEST_APPDATA')
os = {
    getenv = function(name) if name == 'APPDATA' then return TEST_APPDATA end return nil end,
    clock = real_os.clock,
    time = real_os.time,
    date = real_os.date,
}

local function rec(s) __READS[#__READS + 1] = s end

-- ============================================================= fake memory
-- Regions are plain Lua strings at increasing addresses.
local REGIONS = {}

local function add_region(base, data)
    REGIONS[#REGIONS + 1] = { base = base, data = data }
end

local function blank(n) return string.rep('\0', n) end

local function place(s, off, block)
    return s:sub(1, off) .. block .. s:sub(off + #block + 1)
end

local function put_i32(s, off, v)
    local b = { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256,
                math.floor(v / 16777216) % 256 }
    for i = 1, 4 do
        s = s:sub(1, off + i - 1) .. string.char(b[i]) .. s:sub(off + i + 1)
    end
    return s
end

local function put_f32(s, off, v)
    -- round-trip through a Lua number representation good enough for 30000.0
    local b = { 0, 0, 0, 0 }
    local neg = v < 0
    local a = math.abs(v)
    local exp = 0
    if a == 0 then
        b = { 0, 0, 0, 0 }
    else
        while a >= 2 do a = a / 2; exp = exp + 1 end
        while a < 1 do a = a * 2; exp = exp - 1 end
        local mant = math.floor((a - 1) * 8388608 + 0.5)
        local bits = (exp + 127) * 8388608 + mant
        if neg then bits = bits + 2147483648 end
        b = { bits % 256, math.floor(bits / 256) % 256,
              math.floor(bits / 65536) % 256, math.floor(bits / 16777216) % 256 }
    end
    for i = 1, 4 do
        s = s:sub(1, off + i - 1) .. string.char(b[i]) .. s:sub(off + i + 1)
    end
    return s
end

-- A genuine HealthComponent: every fixed field and all 38 damage zones.
local function health_component(health, total_len)
    local s = blank(total_len)
    s = put_i32(s, 0x00, health)        -- Health
    s = put_f32(s, 0x04, 0.0)           -- HealthChangerate
    s = put_i32(s, 0x18, 0)             -- Constitution
    s = put_i32(s, 0x28, 3)             -- Size == UnitSize_Massive
    s = put_f32(s, 0x2C, 30000.0)       -- Mass
    s = put_i32(s, 0x30, 2000)          -- KillScore
    s = put_i32(s, 0x40 + 0xE8, -1)     -- DefaultDamageableZoneInfo.Health == -1
    local zone_health = { 150000, 150000, 15000, 15000, 15000, 15000, 15000, 15000,
                          20000, 15000, 15000, 15000, 15000, 15000, 15000, 150000,
                          150000, 150000, 150000, 150000, 150000, 150000, 10000, 10000,
                          5000, 5000, 5000, 5000, 5000, 5000, 5000, 5000,
                          5000, 5000, 5000, 5000, 5000, 5000 }
    local zone_const = { 0, 0, 35000, 35000, 35000, 35000, 35000, 35000,
                         35000, 35000, 35000, 35000, 35000, 35000, 35000, 0,
                         0, 0, 0, 0, 0, 0, 0, 0 }
    for k = 0, 37 do
        local z = 0x208 + k * 552
        s = put_i32(s, z + 0xE8, zone_health[k + 1] or 5000)
        s = put_i32(s, z + 0xEC, zone_const[k + 1] or 0)
    end
    return s
end

-- Region 1: 0x10000000, one real component at +0x100, and a decoy at +0x6000.
-- A component needs 0x208 + 38*552 = 21496 bytes of zone array, so the block is
-- 22000 bytes; sizing it smaller silently truncates the zone strand.
local r1 = blank(0x8000)
r1 = place(r1, 0x100, health_component(150000, 22000))
-- Decoy: correct signature, but Size/Mass/KillScore are wrong -> score < 4.
local decoy = blank(0x400)
decoy = put_i32(decoy, 0x00, 150000)
decoy = put_f32(decoy, 0x04, 0.0)
decoy = put_i32(decoy, 0x18, 7)
decoy = put_i32(decoy, 0x28, 9)
decoy = put_f32(decoy, 0x2C, 12.5)
decoy = put_i32(decoy, 0x30, 5)
r1 = place(r1, 0x6000, decoy)
add_region(0x10000000, r1)

-- Region 2: a signature straddles a chunk seam.  The tests set chunk=65536 in
-- hivelord_mem.cfg, so 65536*4 = 262144 is a real seam.  The scanner now keys on
-- the 12-byte archetype block at component+0x28 (Size=3 | Mass=30000.0f |
-- KillScore=2000), so *that* pattern has to be the one spanning the seam --
-- placing the component where the old 150000 value pattern spanned it would leave
-- the chunk overlap unexercised and the no-overlap mutation would escape.
local seam = 65536 * 4
local seam_off = seam - 2 - 0x28
local r2 = place(blank(seam_off + 23000), seam_off, health_component(150000, 22000))
add_region(0x20000000, r2)

-- Region 3: small region, nothing interesting.
add_region(0x30000000, blank(0x1000))

-- Region 4: a *damaged* live copy, so the watch loop has something to see.
local live = health_component(90000, 22000)
add_region(0x40000000, live)

-- Region 5: THE SHAPE THAT MOTIVATED THE INVARIANT SIGNATURE -- the one the old
-- scanner could never find.  A live session produced exactly this: a hit with a
-- damaged Health and NO usable zone array ("health=150000 zones=3 magic=0").  The
-- 150000 value signature cannot match a damaged Health, and the zone fallback needs
-- an intact 15000/35000 plate pair, so this block was invisible to both.  Only a
-- signature built from constants that damage never touches can find it.
local slim = blank(22000)
slim = put_i32(slim, 0x00, 4711)          -- damaged: deliberately NOT 150000
slim = put_f32(slim, 0x04, 0.0)           -- HealthChangerate
slim = put_i32(slim, 0x18, 0)             -- Constitution
slim = put_i32(slim, 0x28, 3)             -- Size == UnitSize_Massive
slim = put_f32(slim, 0x2C, 30000.0)       -- Mass
slim = put_i32(slim, 0x30, 2000)          -- KillScore
slim = put_i32(slim, 0x40 + 0xE8, -1)     -- DefaultDamageableZoneInfo.Health
-- Every zone slot reads 0xFFFFFFFF: out of range, so plausible/magic stay 0 and the
-- readout must fall back to the main health alone.
slim = slim:sub(1, 0x208) .. string.rep('\255', 22000 - 0x208)
add_region(0x50000000, slim)

local function region_of(addr)
    for _, r in ipairs(REGIONS) do
        if addr >= r.base and addr < r.base + #r.data then return r, addr - r.base end
    end
    return nil, nil
end

-- ============================================================= fake ffi
local ffi = {}

function ffi.abi(what) if what == '64bit' then return true end return false end
function ffi.cdef(_) end

local function buf_new(n)
    return { __buf = blank(n), __size = n, __ctype = 'uint8_t[' .. n .. ']' }
end

function ffi.new(ctype, a, b)
    if ctype == 'HL_SYSTEM_INFO' then
        return { lpMinimumApplicationAddress = { __ptr = 0x10000 },
                 lpMaximumApplicationAddress = { __ptr = 0x7FFFFFFFFFFF } }
    elseif ctype == 'HL_MEMORY_BASIC_INFORMATION' then
        return { BaseAddress = 0, RegionSize = 0, State = 0, Protect = 0 }
    elseif ctype == 'size_t[1]' then
        return { [0] = 0 }
    elseif ctype == 'uintptr_t[1]' then
        return { [0] = 0 }
    elseif ctype == 'uint8_t[4]' then
        return buf_new(4)
    elseif type(ctype) == 'string' and ctype:match('^uint8_t%[%?%]$') then
        return buf_new(a)
    elseif type(ctype) == 'string' and ctype:match('^uint8_t%[%d+%]$') then
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
    len = len or buf.__size
    return buf.__buf:sub(1, len)
end

function ffi.copy(dst, src, n)
    if type(dst) ~= 'table' or not dst.__buf then error('ffi.copy: dst is not a buffer') end
    if type(src) ~= 'string' then error('ffi.copy: src is not a string') end
    n = n or #src
    dst.__buf = src:sub(1, n) .. dst.__buf:sub(n + 1)
end

local function read_f32_at(buf, off)
    local bytes = { buf.__buf:byte(off + 1, off + 4) }
    local bits = bytes[1] + bytes[2] * 256 + bytes[3] * 65536 + bytes[4] * 16777216
    local sign = 1
    if bits >= 2147483648 then sign = -1; bits = bits - 2147483648 end
    local exp = math.floor(bits / 8388608)
    local mant = bits % 8388608
    if exp == 0 and mant == 0 then return 0.0 end
    return sign * (1 + mant / 8388608) * (2 ^ (exp - 127))
end

function ffi.cast(ctype, v)
    if ctype == 'uintptr_t' then
        if type(v) == 'number' then return v end
        if type(v) == 'table' and v.__ptr then return v.__ptr end
        error('ffi.cast(uintptr_t): bad value')
    elseif ctype == 'const void *' then
        if type(v) ~= 'number' then error('ffi.cast(const void *): expected a number') end
        return { __ptr = v }
    elseif ctype == 'float *' then
        if type(v) ~= 'table' or not v.__buf then error('ffi.cast(float *): not a buffer') end
        return setmetatable({}, { __index = function(_, k)
            if k == 0 then return read_f32_at(v, 0) end
            return nil
        end })
    end
    error('ffi.cast: unsupported ctype ' .. tostring(ctype))
end

local KERNEL = {}
function KERNEL.GetCurrentProcess() return { __ptr = 1 } end

function KERNEL.GetSystemInfo(info)
    info.lpMinimumApplicationAddress = { __ptr = 0x10000 }
    info.lpMaximumApplicationAddress = { __ptr = 0x7FFFFFFFFFFF }
end

function KERNEL.VirtualQuery(addr, info, len)
    local a = (type(addr) == 'table' and addr.__ptr) or addr
    if type(a) ~= 'number' then error('VirtualQuery: address must be a pointer') end
    local sorted = {}
    for _, r in ipairs(REGIONS) do sorted[#sorted + 1] = r end
    table.sort(sorted, function(x, y) return x.base < y.base end)
    -- Inside a mapped region?  Report it.
    for _, r in ipairs(sorted) do
        if a >= r.base and a < r.base + #r.data then
            info.BaseAddress = r.base
            info.RegionSize = #r.data
            info.State = 0x1000          -- MEM_COMMIT
            info.Protect = 0x04          -- PAGE_READWRITE
            return 48
        end
    end
    -- Otherwise report the *gap* up to the next mapping as free memory.  Without
    -- this the walk never advances past the first region, which is exactly the
    -- bug this fixture was built to expose.
    local nextbase = 0x7FFFFFFFFFFF
    for _, r in ipairs(sorted) do
        if r.base > a and r.base < nextbase then nextbase = r.base end
    end
    local size = nextbase - a
    if size <= 0 then return 0 end
    info.BaseAddress = a
    info.RegionSize = size
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
    rec(string.format('read 0x%x %d', address.__ptr, size))
    if size >= 65536 then __BIG_READS = __BIG_READS + 1 end
    return 1
end

function ffi.load(name)
    if name ~= 'kernel32' then error('ffi.load: only kernel32 is stubbed') end
    return KERNEL
end

_G.ffi = ffi

-- The addon acquires FFI with require('ffi'), exactly as the game exposes it.
-- Without this the addon correctly refuses to run, and the whole suite silently
-- tests nothing.
local real_require = require
_G.require = function(name)
    if name == 'ffi' then return ffi end
    if real_require then return real_require(name) end
    error('module not found: ' .. tostring(name))
end

-- ============================================================ driver helpers
-- Flip the live copy's health so the watch loop can observe a change.
function __set_live_health(v)
    for _, r in ipairs(REGIONS) do
        if r.base == 0x40000000 then
            r.data = put_i32(r.data, 0, v)
            return true
        end
    end
    return false
end

-- Destroy the fixed part of the region-1 component, so its fingerprint stops
-- holding and the watcher must drop it rather than read whatever is there.
function __break_fixed(base)
    for _, r in ipairs(REGIONS) do
        if r.base == base then
            r.data = blank(64) .. r.data:sub(65)
            return true
        end
    end
    return false
end

function __reads_text()
    local p = {}
    for _, v in ipairs(__READS) do p[#p + 1] = v end
    return table.concat(p, ',')
end

function __reads_count() return #__READS end
function __read_errors() return __READ_ERRORS end
function __big_reads() return __BIG_READS end

if type(_G.update) ~= 'function' then _G.update = function(...) end end
