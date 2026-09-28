-- HD2-Addon: mods/hivelord/hivelord_memscan
-- Hive Lord health fallback: locate health structures in process memory by
-- signature and watch them.  READ-ONLY.  No engine Lua API is called at all, so
-- this cannot trip the failure mode that crashed an earlier probe.
--
-- WHY THIS EXISTS
--   The primary probe reads health through the engine's own entity API.  If that
--   API turns out to be unusable (it crashed the game twice for an earlier
--   resource) or if the networked field array does not carry the damage-zone
--   maxima, this scanner is the independent second route.
--
-- WHAT IT LOOKS FOR
--   `HealthComponent`, parsed byte-exactly from the plaintext
--   filediver/datalibrary/generated_entities.dl_bin (see
--   work/hivelord/HIVE_LORD_HEALTH.md).  Struct authority is the game's own
--   typelib.  Offsets are relative to the HealthComponent record:
--
--     +0x00  Health                       int32   = 150000   <- the watched value
--     +0x04  HealthChangerate             float32 = 0.0
--     +0x18  Constitution                 int32   = 0
--     +0x28  Size (UnitSize_Massive)      int32   = 3
--     +0x2C  Mass                         float32 = 30000.0
--     +0x30  KillScore                    int32   = 2000
--     +0x208 DamageableZones[38]          stride 552
--             zone.Health        int32 at zone+0xE8
--             zone.Constitution  int32 at zone+0xEC
--
--   The 150000 in that fixed part is only 10 bytes from Size==3, Mass==30000.0
--   and KillScore==2000, which together are a very narrow fingerprint.  The
--   blueprint copy in memory matches it, and so should a per-entity runtime copy;
--   the difference is that the runtime copy's Health drops when it takes damage,
--   which is exactly what the watch loop records.

local ffi_ok, ffi = pcall(require, 'ffi')
if rawget(_G, '__HIVELORD_MEMSCAN_INSTALLED') then return { installed = true } end

-- Read the loader marker up front so every log line and the status file can carry
-- the environment; and only touch FFI if it actually exists, because the gates
-- that report a missing FFI now run *after* logging is available.
local loader = rawget(_G, 'CowboyBingusModLoader')
local loader_api = type(loader) == 'table' and tonumber(loader.api) or nil
local loader_version = type(loader) == 'table' and tonumber(loader.version) or nil

local kernel, process
if ffi_ok and type(ffi) == 'table' and ffi.abi('64bit') then
ffi.cdef [[
    typedef struct {
        uint64_t BaseAddress;
        uint64_t AllocationBase;
        uint32_t AllocationProtect;
        uint32_t __alignment1;
        uint64_t RegionSize;
        uint32_t State;
        uint32_t Protect;
        uint32_t Type;
        uint32_t __alignment2;
    } HL_MEMORY_BASIC_INFORMATION;
    typedef struct {
        uint16_t wProcessorArchitecture;
        uint16_t wReserved;
        uint32_t dwPageSize;
        void    *lpMinimumApplicationAddress;
        void    *lpMaximumApplicationAddress;
        uint64_t dwActiveProcessorMask;
        uint32_t dwNumberOfProcessors;
        uint32_t dwProcessorType;
        uint32_t dwAllocationGranularity;
        uint16_t wProcessorLevel;
        uint16_t wProcessorRevision;
    } HL_SYSTEM_INFO;
    void *GetCurrentProcess(void);
    int   ReadProcessMemory(void *process, const void *address, void *buffer,
                            size_t size, size_t *read);
    size_t VirtualQuery(const void *address, HL_MEMORY_BASIC_INFORMATION *info,
                        size_t length);
    void  GetSystemInfo(HL_SYSTEM_INFO *info);
]]
kernel = ffi.load('kernel32')
process = kernel.GetCurrentProcess()
end

local MEM_COMMIT, MEM_FREE = 0x1000, 0x10000
local PAGE_GUARD, PAGE_NOACCESS = 0x100, 0x01

-- ---------------------------------------------------------------- configuration
local C = {
    debug = true,
    chunk = 512 * 1024,       -- bytes per ReadProcessMemory call
    budget_ms = 6,            -- CPU budget per frame for scanning
    start_delay = 600,        -- frames before scanning begins
    watch_seconds = 2,        -- re-read interval once candidates are found
    max_matches = 256,        -- cap on verified structures
    hex_dump = 256,           -- bytes of hex context per match
    rescan_seconds = 120,     -- re-scan interval; a target that spawns late needs it
    max_plausible_health = 150000,  -- a health value above the Hive Lord's maximum is
                                    -- a reused allocation, not a reading
}
local dir = os.getenv and os.getenv('APPDATA') or nil
if dir and io and io.open then
    local f = io.open(dir .. '/Arrowhead/Helldivers2/hivelord_mem.cfg', 'r')
    if f then
        for l in f:lines() do
            local k, v = l:match('^%s*([%w_]+)%s*=%s*([%w%.%-]+)')
            if k == 'debug' then C.debug = (v == 'true')
            elseif C[k] ~= nil then
                if v == 'true' then C[k] = true
                elseif v == 'false' then C[k] = false
                else
                    local n = tonumber(v)
                    if n and n == n and n >= 0 then C[k] = n end
                end
            end
        end
        f:close()
    end
end

-- -------------------------------------------------------------------- logging
-- Opened, appended and closed per line.  A live session left this log at 0 bytes
-- while the status file kept working: a buffered write whose flush raises loses the
-- line when the handle is dropped.  Per-line append cannot lose anything.
local outdir, log_path
local log_ok, log_fail = 0, 0
if io and io.open then
    local la = os.getenv and os.getenv('LOCALAPPDATA') or nil
    local tp = os.getenv and os.getenv('TEMP') or nil
    local cands = {}
    if dir then cands[#cands + 1] = dir .. '/Arrowhead/Helldivers2' end
    if la then cands[#cands + 1] = la .. '/CowboyBingus/Helldivers2/Logs' end
    if tp then cands[#cands + 1] = tp end
    cands[#cands + 1] = '.'
    for _, d in ipairs(cands) do
        local probe = io.open(d .. '/hivelord_mem.log', 'a')
        if probe then
            outdir = d
            log_path = d .. '/hivelord_mem.log'
            pcall(function() probe:close() end)
            break
        end
    end
end
local function w(line)
    if not log_path or not io or not io.open then return end
    local f = io.open(log_path, 'a')
    if not f then log_fail = log_fail + 1; return end
    local ok = pcall(function() f:write(line, '\n'); f:close() end)
    if not ok then
        pcall(function() f:close() end)
        log_fail = log_fail + 1
        return
    end
    log_ok = log_ok + 1
end
local function wf(fmt, ...) w(string.format(fmt, ...)) end
wf('LOG_OPEN path=%s', tostring(log_path))

local STATUS = {}
local function status(line)
    STATUS[#STATUS + 1] = line
    if not outdir then return end
    local f = io.open(outdir .. '/hivelord_mem_STATUS.txt', 'w')
    if f then
        f:write('hivelord-memscan-v1.1.0 (read-only)\n')
        f:write('loader api=' .. tostring(loader_api) .. ' version=' .. tostring(loader_version) .. '\n')
        f:write('log: ' .. tostring(log_path) .. ' lines=' .. log_ok .. ' failed=' .. log_fail .. '\n')
        for _, v in ipairs(STATUS) do f:write(v, '\n') end
        f:close()
    end
end

-- Gates run after logging exists so that a scanner which is loaded but cannot
-- work still leaves a file saying why, instead of appearing to do nothing.
local function refuse(reason)
    wf('REFUSED %s', reason)
    status('REFUSED - ' .. reason)
    return { installed = false, reason = reason }
end
if not ffi_ok or type(ffi) ~= 'table' then
    return refuse('the ffi builtin is unavailable; cannot read memory')
end
if not ffi.abi('64bit') then return refuse('this build is not 64-bit') end
if not kernel then return refuse('kernel32 could not be loaded') end
if loader_api and loader_api < 1 then
    return refuse('Bingus Shared Loader API is ' .. tostring(loader_api) .. ', need >= 1')
end

local function state_path() return outdir and (outdir .. '/hivelord_mem_state.txt') end
local function save_cursor(region_index)
    local p = state_path()
    if not p or not io or not io.open then return end
    local f = io.open(p, 'w')
    if f then f:write(string.format('region_cursor=%d\n', region_index)); f:close() end
end
local function load_cursor()
    local p = state_path()
    if not p or not io or not io.open then return 1 end
    local f = io.open(p, 'r')
    if not f then return 1 end
    local v = 1
    for l in f:lines() do
        local n = l:match('^region_cursor=(%d+)')
        if n then v = tonumber(n) end
    end
    f:close()
    if v < 1 then v = 1 end
    return v
end

-- ------------------------------------------------------- byte helpers (pure Lua)
-- LuaJIT numbers are doubles: only 53 bits.  Every one of these reads small
-- fields from a string, so nothing over 2^53 is ever put in a number.
local function le_bytes_from_hex(hex)
    return (hex:gsub('%x%x', function(p) return string.char(tonumber(p, 16)) end))
end

-- 150000 as int32 LE followed by float 0.0 -> the signature to search for.
-- KEPT ONLY AS A SECONDARY PATTERN.  By construction it can only match an *undamaged*
-- Hive Lord, because as soon as the entity takes damage its Health is no longer 150000.
-- Four to eight full passes over this process found the memory-mapped data table and
-- nothing else, and one live session produced exactly one "live-like" hit that then
-- went MATCH_STALE: the value signature was looking for a number that damage destroys.
local HIVE_LORD_SIG = le_bytes_from_hex('f0490200' .. '00000000')

-- THE PRIMARY PATTERN: the archetype invariants, not a health value.
--
--   +0x28  Size      int32   = 3          (UnitSize_Massive)
--   +0x2C  Mass      float32 = 30000.0
--   +0x30  KillScore uint32  = 2000
--
-- Verified offline against the game's own 45,630,790-byte generated_entities.dl_bin
-- (work/hivelord/sig_specificity.py): these 12 bytes occur EXACTLY ONCE in the whole
-- file, at 0x7F4A1E = the Hive Lord's record[27] + 0x28.  Individually, Mass==30000.0
-- is unique among all 493 HealthComponent records and KillScore==2000 is unique too
-- (Size==3 alone is shared by 46 records, which is why all three are required).
--
-- Damage never touches any of the three, so a per-entity runtime copy still matches
-- after the Hive Lord has been hurt -- which is the whole point.  The component base is
-- therefore pattern_addr - INV_SIG_OFF, and main Health is at base + 0x00.
local INV_SIG_OFF = 0x28
local HIVE_LORD_INV_SIG = le_bytes_from_hex('03000000' .. '0060ea46' .. 'd0070000')

-- Damage-independent signature: two adjacent zone fields, Health 15000 and
-- Constitution 35000, at zone+0xE8.  Zone maxima never change when the entity
-- takes damage, so this still finds a Hive Lord that was already hurt before the
-- scan started -- the case the main signature misses by construction.
local HIVE_ZONE_SIG = le_bytes_from_hex('983a0000' .. 'b8880000')

local function u32_at(s, off)
    if not s or off < 0 or off + 4 > #s then return nil end
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not a then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function i32_at(s, off)
    local v = u32_at(s, off)
    if v == nil then return nil end
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

local function f32_at(s, off)
    if not s or off < 0 or off + 4 > #s then return nil end
    local buf = ffi.new('uint8_t[4]')
    ffi.copy(buf, s:sub(off + 1, off + 4), 4)
    return ffi.cast('float *', buf)[0]
end

local function hexdump(s, from, len)
    local part = s:sub(from + 1, from + len)
    return (part:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

-- ------------------------------------------------------ structure verification
local MAGIC_HEALTH = {
    [150000] = true, [35000] = true, [15000] = true, [10000] = true,
    [5000] = true, [20000] = true, [800] = true, [2500] = true,
}

-- Byte offset of the Hive Lord's main Health inside generated_entities.dl_bin,
-- from the byte-exact offline parse (record 27, main Health at +0x00).  Used to
-- tell the memory-mapped data table apart from a live per-entity copy.
local HIVELORD_FILE_OFF = 0x7F49F6

-- Score the fixed part.  Returns score (0..5) and a table of the observed values.
local function score_fixed(s, base)
    local got = {}
    local score = 0
    if i32_at(s, base + 0x00) == 150000 then score = score + 1 end
    got.health = i32_at(s, base + 0x00)
    local cr = f32_at(s, base + 0x04)
    got.changerate = cr
    if cr == 0.0 then score = score + 1 end
    got.constitution = i32_at(s, base + 0x18)
    if got.constitution == 0 then score = score + 1 end
    got.size = i32_at(s, base + 0x28)
    if got.size == 3 then score = score + 1 end
    got.mass = f32_at(s, base + 0x2C)
    if got.mass and math.abs(got.mass - 30000.0) < 0.5 then score = score + 1 end
    got.kill_score = i32_at(s, base + 0x30)
    if got.kill_score == 2000 then score = score + 1 end
    return score, got
end

-- Same fixed part, but the health value is allowed to have dropped.  Used when a
-- record is reached from the zone signature instead of from the 150000 one, so
-- it must not require full health -- that is the whole point.
local function score_fixed_loose(s, base)
    local got = {}
    local score = 0
    local h = i32_at(s, base + 0x00)
    got.health = h
    if h and h > 0 and h <= 150000 then score = score + 1 end
    local cr = f32_at(s, base + 0x04)
    got.changerate = cr
    if cr == 0.0 then score = score + 1 end
    got.constitution = i32_at(s, base + 0x18)
    if got.constitution == 0 then score = score + 1 end
    got.size = i32_at(s, base + 0x28)
    if got.size == 3 then score = score + 1 end
    got.mass = f32_at(s, base + 0x2C)
    if got.mass and math.abs(got.mass - 30000.0) < 0.5 then score = score + 1 end
    got.kill_score = i32_at(s, base + 0x30)
    if got.kill_score == 2000 then score = score + 1 end
    return score, got
end

-- The archetype-invariant score, used by the primary path.  It is the ONLY scorer that
-- is allowed to accept a health value other than 150000, and it may do so because the
-- three constants it demands are unique to the Hive Lord across all 493 records.
local function score_invariant(s, base)
    local got = {}
    local score = 0
    local h = i32_at(s, base + 0x00)
    got.health = h
    if h and h > 0 and h <= 150000 then score = score + 1 end
    got.size = i32_at(s, base + 0x28)
    if got.size == 3 then score = score + 1 end
    got.mass = f32_at(s, base + 0x2C)
    if got.mass and math.abs(got.mass - 30000.0) < 0.5 then score = score + 1 end
    got.kill_score = i32_at(s, base + 0x30)
    if got.kill_score == 2000 then score = score + 1 end
    got.constitution = i32_at(s, base + 0x18)
    if got.constitution == 0 then score = score + 1 end
    local cr = f32_at(s, base + 0x04)
    got.changerate = cr
    if cr == 0.0 then score = score + 1 end
    return score, got
end

-- Count how many of the 38 damage zones carry a plausible Health at stride 552.
-- This is what separates a real HealthComponent from a coincidental 150000.
local ZONE_BASE, ZONE_STRIDE, ZONE_COUNT = 0x208, 552, 38
local ZONE_HEALTH_OFF, ZONE_CONST_OFF = 0xE8, 0xEC
local function score_zones(s, base)
    local plausible, magic, first = 0, 0, {}
    for k = 0, ZONE_COUNT - 1 do
        local z = base + ZONE_BASE + k * ZONE_STRIDE
        local h = i32_at(s, z + ZONE_HEALTH_OFF)
        local c = i32_at(s, z + ZONE_CONST_OFF)
        if h and c and h >= 0 and h <= 1000000 and c >= 0 and c <= 1000000 then
            plausible = plausible + 1
            if MAGIC_HEALTH[h] then magic = magic + 1 end
            if k < 8 then first[#first + 1] = string.format('%d/%d', h, c) end
        end
    end
    return plausible, magic, table.concat(first, ' ')
end

-- ------------------------------------------------------------ region inventory
local M = {
    frame = 0, clock = 0,
    regions = nil, region_index = 1, region_off = 0, region_scanned = 0,
    matches = {}, match_at = {}, watch_at = 0, bytes = 0, started = false,
    deadline = 0,
    -- Pattern hit counters.  Without these, "the signature never matched anything" and
    -- "the signature matched but every candidate was rejected" look identical in the log
    -- -- and they need opposite fixes.  Cost of carrying them is two increments.
    inv_hits = 0, fixed_hits = 0, zone_hits = 0,
}

local function build_regions()
    local info = ffi.new('HL_SYSTEM_INFO')
    kernel.GetSystemInfo(info)
    local lo = tonumber(ffi.cast('uintptr_t', info.lpMinimumApplicationAddress))
    local hi = tonumber(ffi.cast('uintptr_t', info.lpMaximumApplicationAddress))
    if not lo or lo < 0x10000 then lo = 0x10000 end
    if not hi or hi <= lo then hi = 0x7FFFFFFFFFFF end

    local mbi = ffi.new('HL_MEMORY_BASIC_INFORMATION')
    local list, addr, total = {}, lo, 0
    local guard = 0
    while addr < hi and guard < 2000000 do
        guard = guard + 1
        local got = kernel.VirtualQuery(ffi.cast('const void *', addr), mbi, ffi.sizeof(mbi))
        if got ~= ffi.sizeof(mbi) or mbi.RegionSize == 0 then break end
        local size = tonumber(mbi.RegionSize)
        local prot = tonumber(mbi.Protect)
        if tonumber(mbi.State) == MEM_COMMIT
            and prot ~= PAGE_NOACCESS
            and math.floor(prot / PAGE_GUARD) % 2 == 0 then
            list[#list + 1] = { base = addr, size = size }
            total = total + size
        end
        addr = addr + size
    end
    -- Largest regions first: data tables and component storage live in big blocks.
    table.sort(list, function(a, b) return a.size > b.size end)
    M.regions = list
    wf('REGIONS count=%d total=%d MiB', #list, math.floor(total / 1048576))
    status(string.format('scanned %d readable regions, %d MiB address space',
        #list, math.floor(total / 1048576)))
    return list
end

local function read(addr, size)
    local buf = ffi.new('uint8_t[?]', size)
    local got = ffi.new('size_t[1]')
    local ok = kernel.ReadProcessMemory(process, ffi.cast('const void *', addr), buf, size, got)
    if ok == 0 or got[0] ~= size then return nil end
    return ffi.string(buf, size)
end

local function record_match(addr, blob, base, why, loose)
    if M.match_at[addr] then return end
    if #M.matches >= C.max_matches then return end
    if base + 0x60 > #blob then return end
    local score, got, need
    if why == 'invariant' then
        -- The primary path.  need=5 of 6: health may have dropped (that is the point),
        -- but Size/Mass/KillScore must all hold, so 5 is the arithmetic floor here.
        score, got = score_invariant(blob, base)
        need = 5
    elseif loose then
        score, got = score_fixed_loose(blob, base)
        need = 5
    else
        score, got = score_fixed(blob, base)
        need = 4
    end
    if score < need then return end
    local zone_blob = blob
    if base + ZONE_BASE + ZONE_COUNT * ZONE_STRIDE > #blob then
        zone_blob = read(addr, ZONE_BASE + ZONE_COUNT * ZONE_STRIDE) or blob
    end
    local plausible, magic, first =
        score_zones(zone_blob, zone_blob == blob and base or 0)
    M.match_at[addr] = true
    -- Classify the hit.  The Hive Lord's Health sits at file offset 0x7F49F6 of
    -- generated_entities.dl_bin (byte-exact offline parse), so if subtracting that
    -- offset leaves a 64 KiB aligned base, this is the memory-mapped data table --
    -- the *blueprint*, whose value can never change.  A live per-entity copy would
    -- not land on that alignment.  The first live run's single match satisfied it
    -- exactly (0x22c67de49f6 - 0x7F49F6 = 0x22c675f0000), which is why the watch
    -- loop saw nothing move: it was watching the data file, not the entity.
    local delta = addr - HIVELORD_FILE_OFF
    local kind = 'OTHER'
    if delta > 0 and delta % 0x10000 == 0 then kind = 'BLUEPRINT' end
    M.matches[#M.matches + 1] = { addr = addr, health = got.health, score = score,
                                  zones = plausible, zone_magic = magic, kind = kind,
                                  invariants = (why == 'invariant') }
    wf('MATCH addr=0x%x why=%s fixed_score=%d/6 health=%s constitution=%s size=%s mass=%s kill_score=%s zones_plausible=%d zones_magic=%d first_zones=[%s]',
        addr, why, score, tostring(got.health), tostring(got.constitution),
        tostring(got.size), tostring(got.mass), tostring(got.kill_score),
        plausible, magic, first)
    wf('MATCH_KIND addr=0x%x kind=%s implied_mapping_base=0x%x', addr, kind, delta)
    wf('MATCH_HEX addr=0x%x %s', addr, hexdump(blob, base, C.hex_dump))
    status(string.format('match %s at 0x%x: health=%s zones=%d magic=%d',
        kind, addr, tostring(got.health), plausible, magic))
end

local function scan_region(ri)
    local r = M.regions[ri]
    if not r then return true end
    -- Resume inside the region, not from its start: a region can be far larger
    -- than one frame's budget, and restarting it every frame would never finish.
    local off = M.region_off or 0
    while off < r.size do
        local want = math.min(C.chunk, r.size - off)
        if want < #HIVE_LORD_SIG then break end
        local blob = read(r.base + off, want)
        if blob then
            -- PRIMARY: the archetype invariants (Size==3, Mass==30000.0, KillScore==2000).
            -- These three never change when the entity takes damage, so unlike the 150000
            -- value pattern this also finds a Hive Lord that was already hurt before the
            -- scan began -- the case the old pattern missed by construction.  The
            -- component head is read again from its own base so that a hit sitting on a
            -- chunk seam still yields a complete 0x60-byte fixed part.
            local from = 1
            while true do
                local at = blob:find(HIVE_LORD_INV_SIG, from, true)
                if not at then break end
                from = at + 1
                M.inv_hits = M.inv_hits + 1
                local ca = r.base + off + at - 1 - INV_SIG_OFF
                if ca >= r.base and not M.match_at[ca] then
                    local fb = read(ca, 0x60)
                    if fb then record_match(ca, fb, 0, 'invariant', false) end
                end
                if from > #blob then break end
            end
            from = 1
            while true do
                local at = blob:find(HIVE_LORD_SIG, from, true)
                if not at then break end
                M.fixed_hits = M.fixed_hits + 1
                record_match(r.base + off + at - 1, blob, at - 1, 'fixed', false)
                from = at + 1
                if from > #blob then break end
            end
            -- Zone signature: the hit is a zone's Health field.  Walk the 38
            -- possible zone indices back to the record it belongs to and verify
            -- the fixed part there, allowing a health value below 150000.
            from = 1
            local zone_attempts = 0
            while true do
                local at = blob:find(HIVE_ZONE_SIG, from, true)
                if not at then break end
                from = at + 1
                M.zone_hits = M.zone_hits + 1
                if zone_attempts < 64 then
                    zone_attempts = zone_attempts + 1
                    local zh = r.base + off + at - 1
                    for k = 0, ZONE_COUNT - 1 do
                        local rec = zh - ZONE_HEALTH_OFF - ZONE_BASE - k * ZONE_STRIDE
                        -- The record must live in the same region as the zone hit;
                        -- checking that here keeps the 38-index walk from firing
                        -- reads at unmapped addresses.
                        if rec >= r.base and rec + 0x60 <= r.base + r.size
                            and not M.match_at[rec] then
                            local fb = read(rec, 0x60)
                            if fb then record_match(rec, fb, 0, 'zone', true) end
                        end
                    end
                end
                if from > #blob then break end
            end
            M.bytes = M.bytes + #blob
        end
        if want <= 4096 then off = r.size; break end
        off = off + want - 4096      -- overlap so a signature on a seam is not missed
        if os.clock() > M.deadline then
            M.region_off = off
            return false
        end
    end
    M.region_off = 0
    return true
end

local function advance()
    if not M.started or M.done then return end
    M.deadline = os.clock() + (C.budget_ms / 1000)
    while M.region_index <= #M.regions do
        save_cursor(M.region_index)
        if scan_region(M.region_index) then
            M.region_index = M.region_index + 1
            if M.region_index > #M.regions then
                -- Report completion *before* the budget check.  Returning on the
                -- deadline first meant a small per-frame budget never logged the
                -- summary, which is the one line a one-shot probe must not lose.
                M.done = true
                M.scans = (M.scans or 0) + 1
                M.next_rescan = M.clock + C.rescan_seconds
                -- Reset the cursor to the START of the region list.  It exists to
                -- resume a pass that crashed, so leaving it at the end means the
                -- next session resumes at the end and scans nothing: the live log
                -- showed "SCAN_RESUME region_index=9858 of 9903 ... bytes=0 MiB
                -- matches=0", i.e. the previous session's find was never re-checked
                -- and the watch had nothing to watch.
                save_cursor(1)
                local bp = 0
                for _, mm in ipairs(M.matches) do
                    if mm.kind == 'BLUEPRINT' then bp = bp + 1 end
                end
                wf('SCAN_DONE pass=%d regions=%d bytes=%d MiB pattern_hits(invariant=%d fixed=%d zone=%d) matches=%d blueprint=%d live_like=%d next_rescan_in=%ds',
                    M.scans, #M.regions, math.floor(M.bytes / 1048576),
                    M.inv_hits, M.fixed_hits, M.zone_hits, #M.matches,
                    bp, #M.matches - bp, C.rescan_seconds)
                if M.inv_hits == 0 and M.scans and M.scans >= 1 then
                    -- Say which failure this is.  "Found nothing" is not actionable;
                    -- "the invariant pattern was never present in 6 GB of memory" is.
                    wf('SIGNATURE_MISS the damage-independent pattern was never seen; either no '
                        .. 'Hive Lord exists in this process yet, or its HealthComponent no longer '
                        .. 'carries the archetype constants (report the log, do not redeploy blindly)')
                end
                -- A single pass is not enough: the Hive Lord usually spawns long
                -- after the scan starts, so a live per-entity copy may not exist
                -- yet.  Re-scanning is what turns "found the data table" into
                -- "found the entity".
                status(string.format(
                    'pass %d complete: %d MiB read, %d structure(s) (%d blueprint, %d live-like); rescan in %ds',
                    M.scans, math.floor(M.bytes / 1048576), #M.matches, bp,
                    #M.matches - bp, C.rescan_seconds))
                return
            end
        end
        if os.clock() > M.deadline then return end
    end
end

-- --------------------------------------------------------- full component readout
-- Why this exists at all: the Hive Lord object's 46 *networked* fields never carried its
-- total health.  Measured across a whole live fight and its death, none of the 46 fields
-- went to zero -- the one damage-shaped field was a 6-bit fraction that read 61/63 at the
-- instant the object was destroyed, and the entity's persistent damage mask went
-- 16383 -> 5383 without ever reaching 0.  So the networked field array cannot answer
-- "how much health is left"; the client's own copy of the component can.
--
-- Reading it: main Health at +0x00, then the 38 DamageableZones at +0x208, stride 552,
-- Health at zone+0xE8, Constitution at zone+0xEC, ZoneName at zone+0x60 -- the same
-- layout the byte-exact offline parse established, so the two can be cross-checked.
local COMP_SIZE = ZONE_BASE + ZONE_COUNT * ZONE_STRIDE      -- 0x53F8 = 21496

-- Known-good totals for the *data table* copy.  If the offsets are right, the blueprint
-- must report exactly these; anything else means the layout moved (build drift) and the
-- live numbers must not be trusted.
--   9 x 150000 + 12 x 15000 + 1 x 20000 + 2 x 10000 + 14 x 5000 = 1,640,000 zone health
--   13 zones carry a 35000 constitution = 455,000
--   plus the record's own main Health 150000 -> 1,790,000
local BP_EXPECT = { main = 150000, zone_sum = 1640000, total = 1790000, const35k = 13 }

local function report_live(m, blob)
    if not blob or #blob < COMP_SIZE then
        wf('LIVE_TIMEOUT addr=0x%x got=%s want=%d', m.addr, tostring(blob and #blob), COMP_SIZE)
        return
    end
    local main_h = i32_at(blob, 0x00) or -1
    local main_c = i32_at(blob, 0x18) or -1
    local sum_h, sum_c, const35k, plausible, named = 0, 0, 0, 0, 0
    local lines = {}
    for k = 0, ZONE_COUNT - 1 do
        local z = ZONE_BASE + k * ZONE_STRIDE
        local h = i32_at(blob, z + ZONE_HEALTH_OFF)
        local c = i32_at(blob, z + ZONE_CONST_OFF)
        local nm = u32_at(blob, z + 0x60)
        h = h or -1
        c = c or -1
        nm = nm or 0
        if h >= 0 and h <= 1000000 and c >= 0 and c <= 1000000 then plausible = plausible + 1 end
        if h > 0 then sum_h = sum_h + h end
        if c > 0 then sum_c = sum_c + c end
        if c == 35000 then const35k = const35k + 1 end
        if nm ~= 0 then named = named + 1 end
        lines[#lines + 1] = string.format('%2d  health=%-7d constitution=%-6d name=0x%08X',
            k, h, c, nm)
    end
    local total = main_h + sum_h
    local sig = string.format('%d/%d/%d', main_h, sum_h, sum_c)
    if m.sig ~= sig then
        m.sig = sig
        wf('LIVE_COMPONENT addr=0x%x kind=%s main=%d main_constitution=%d zone_health_sum=%d '
            .. 'TOTAL=%d zone_constitution_sum=%d const35000=%d/13 zones_plausible=%d/38 named=%d',
            m.addr, m.kind or '?', main_h, main_c, sum_h, total, sum_c, const35k, plausible, named)
        if m.kind == 'BLUEPRINT' then
            local ok = (main_h == BP_EXPECT.main and sum_h == BP_EXPECT.zone_sum
                        and total == BP_EXPECT.total and const35k == BP_EXPECT.const35k)
            wf('LIVE_LAYOUT_CHECK addr=0x%x expected main=%d zone_sum=%d total=%d const35000=%d -> %s',
                m.addr, BP_EXPECT.main, BP_EXPECT.zone_sum, BP_EXPECT.total, BP_EXPECT.const35k,
                ok and 'OK (offsets are right)' or 'MISMATCH (layout moved; do not trust live values)')
            status(ok and 'layout check OK on the data table; live totals are trustworthy'
                       or 'LAYOUT MISMATCH on the data table; live totals are NOT trustworthy')
        else
            status(string.format('LIVE Hive Lord at 0x%x: main=%d zone_sum=%d TOTAL=%d',
                m.addr, main_h, sum_h, total))
            -- Only a live copy is worth dumping: the data table never changes.
            if outdir and io and io.open then
                local f = io.open(outdir .. '/hivelord_mem_live.txt', 'w')
                if f then
                    f:write(string.format('# %s addr=0x%x kind=%s\n', m.kind or '?', m.addr, m.kind or '?'))
                    f:write(string.format('# main=%d zone_health_sum=%d TOTAL=%d const35000=%d\n',
                        main_h, sum_h, total, const35k))
                    f:write(string.format('  0  health=%-7d constitution=%-6d name=(main)\n', main_h, main_c))
                    for _, l in ipairs(lines) do f:write(l, '\n') end
                    f:close()
                end
            end
        end
    end
end

local function watch()
    if #M.matches == 0 then return end
    local live, stale, rejected = {}, 0, 0
    -- Walk backwards so a dropped match can be removed in place.
    for i = #M.matches, 1, -1 do
        local m = M.matches[i]
        local blob = read(m.addr, 0x60)
        -- Re-validate the fingerprint before believing the value.  A live session
        -- watched 0x7edbe650 and logged "health 185 -> 815043536": the block had
        -- been freed and a different allocation occupied the address, but the
        -- watcher kept reading it as if it were the component.  A pinned address is
        -- not a fact; only a re-validated one is.
        --
        -- Which fingerprint depends on how the match was found.  An invariant match was
        -- accepted with a *damaged* health, so it must be re-validated the same way:
        -- re-checking it against "health == 150000" would throw away the one hit that
        -- matters as soon as the Hive Lord has been hurt.
        local vscore, vneed = 0, m.invariants and 5 or 4
        if blob then
            if m.invariants then vscore = score_invariant(blob, 0)
            else vscore = score_fixed(blob, 0) end
        end
        if vscore < vneed then
            stale = stale + 1
            wf('MATCH_STALE addr=0x%x kind=%s (fingerprint no longer holds; will re-resolve)',
                m.addr, m.kind or '?')
            table.remove(M.matches, i)
            M.match_at[m.addr] = nil
        else
            local h = i32_at(blob, 0)
            if h and h >= 0 and h <= C.max_plausible_health then
                live[#live + 1] = string.format('0x%x=%d(%s)', m.addr, h, m.kind or '?')
                if h ~= m.health then
                    wf('WATCH_CHANGE addr=0x%x kind=%s health %s -> %d',
                        m.addr, m.kind or '?', tostring(m.health), h)
                    m.health = h
                    m.changed = true
                end
                -- The networked field array could never produce this number, so every
                -- invariant hit gets the full component parse: main health plus all 38
                -- zones, which is the actual HP the display needs.
                if m.invariants then
                    local full = read(m.addr, COMP_SIZE)
                    local ok, err = pcall(report_live, m, full)
                    if not ok then wf('LIVE_ERROR addr=0x%x %s', m.addr, tostring(err)) end
                end
            else
                rejected = rejected + 1
                wf('WATCH_REJECT addr=0x%x raw=%s (outside 0..%d; not a health value)',
                    m.addr, tostring(h), C.max_plausible_health)
            end
        end
    end
    wf('WATCH n=%d stale=%d rejected=%d %s', #live, stale, rejected,
        table.concat(live, ' '))
end

local function update(dt, ...)
    M.frame = M.frame + 1
    local step = type(dt) == 'number' and dt or 0.016667
    if step < 0 then step = 0 elseif step > 0.25 then step = 0.25 end
    M.clock = M.clock + step

    if not M.started and M.frame > C.start_delay then
        M.started = true
        wf('START memscan-v1.1.0 frame=%d chunk=%d budget_ms=%s', M.frame, C.chunk,
            tostring(C.budget_ms))
        local ok, err = pcall(build_regions)
        if not ok then
            wf('REGIONS_ERROR %s', tostring(err))
            status('ERROR: ' .. tostring(err))
            M.regions = {}
            return
        end
        M.region_index = load_cursor()
        if M.region_index > #M.regions then M.region_index = 1 end
        M.region_off = 0
        wf('SCAN_RESUME region_index=%d of %d', M.region_index, #M.regions)
    end
    if not M.regions then return end

    if not M.done then
        -- Never swallow this: a silent pcall failure is indistinguishable from
        -- "still scanning" and would burn the whole session.
        local ok, err = pcall(advance)
        if not ok then
            wf('SCAN_ERROR region=%d off=%s %s', M.region_index,
                tostring(M.region_off), tostring(err))
            status('SCAN_ERROR: ' .. tostring(err))
            M.region_index = M.region_index + 1
            M.region_off = 0
            if M.region_index > #M.regions then M.done = true end
        end
    elseif M.clock >= (M.next_rescan or 0) and C.rescan_seconds > 0 then
        -- Start another pass over the same region list.  Already-known addresses
        -- are deduplicated by M.match_at, so a pass only adds what is new.
        M.done = false
        M.region_index = 1
        M.region_off = 0
        M.bytes = 0
        wf('RESCAN start pass=%d known_matches=%d', (M.scans or 0) + 1, #M.matches)
    elseif M.clock >= M.watch_at then
        M.watch_at = M.clock + C.watch_seconds
        local ok, err = pcall(watch)
        if not ok then wf('WATCH_ERROR %s', tostring(err)) end
    end
end

local old = rawget(_G, 'update')
if type(old) ~= 'function' then return { installed = false, reason = 'no global update' } end
rawset(_G, '__HIVELORD_MEMSCAN_INSTALLED', true)
local failed = false
rawset(_G, 'update', function(...)
    if not failed then
        local ok, err = pcall(update, ...)
        if not ok then
            failed = true
            wf('LUA_ERROR %s', tostring(err))
            status('LUA_ERROR: ' .. tostring(err))
        end
    end
    return old(...)
end)
status('memscan armed; scanning starts after ' .. C.start_delay .. ' frames')
return { installed = true }
