-- HD2-Addon: mods/hivelord/hivelord_health
-- Hive Lord exact health, by the method of the Enemy HP mod.
--
-- Enemy HP 1.1.1 reads exact per-entity health from the game's health manager:
--
--   hm   = *(game + 0x3326688)            the manager singleton
--   n    = u32 AT hm + 0x1020             entry count
--   arr  = *(hm + 0x1048)                 descriptor pointer array
--   recs = *(hm + 0x1058)                 record array, stride 0x1B8
--   d    = *(arr + j*8)                   [u64 type][u32 entity][u32 unit][u32 goid][u32 flags]
--   hp   = i32 at recs + j*0x1B8 + 0x14   CURRENT health, exactly
--
-- and the maximum from the health table keyed by the descriptor's type:
--
--   net  = *(game + 0x346BF98); t = *(net + 0xF12B78)
--   key  = descriptor type; probe t[key % 1002] forward, 16 bytes per slot (u64 key, u32 idx)
--   max  = u32 at t + 0x3EA0 + idx * 0x5650
--
-- Every one of those addresses belongs to ONE build.  Enemy HP identifies that build from
-- the PE headers of game.dll and helldivers2.exe and stays off on anything else, and this
-- does the same.  Verified against this install offline (work/verify_enemyhp_build.py):
--
--   game.dll        TimeDateStamp 0x6AB3B43F  SizeOfImage 0x04744000  CheckSum 0x00ECDA6F
--   helldivers2.exe TimeDateStamp 0x6AB382E4  SizeOfImage 0x039E8000  CheckSum 0x00E48B1D
--   build 25480438
--
-- Read-only: GetModuleHandleA, GetCurrentProcess, ReadProcessMemory.  No writes, no
-- VirtualProtect, no other process, no code pages touched.
--
-- Why this exists next to hivelord_hp.lua: that reader walks the networked field array,
-- which carries no absolute health (its damage field saturates and never reaches zero at
-- death).  This reads the manager instead, so it gives a real number.  It is deliberately
-- a separate addon because it depends on one exact build while the field reader does not.

local loader = rawget(_G, 'CowboyBingusModLoader')
local loader_api = type(loader) == 'table' and tonumber(loader.api) or nil
local loader_version = type(loader) == 'table' and tonumber(loader.version) or nil

local C = {
    manager_rva = 0x3326688,
    network_rva = 0x346BF98,
    table_off = 0xF12B78,
    count_off = 0x1020,
    arr_off = 0x1048,
    recs_off = 0x1058,
    record_stride = 0x1B8,
    hp_off = 0x14,
    -- [u64 type][u32 entity][u32 unit][u32 goid][u32 flags].  Every field used below ends
    -- at +20, but the read takes the whole 24 so the layout is documented in one place and
    -- the read is bounded by the real size.
    descriptor_size = 24,
    table_slots = 1002,
    slot_size = 16,
    records_off = 0x3EA0,
    health_stride = 0x5650,
    max_entries = 2048,
    poll_seconds = 1,
    diag_seconds = 10,
    by_max_seconds = 10,
    -- How long a reading survives the entry briefly leaving the manager (it churns).
    hold_seconds = 2,
    start_delay = 300,
    hud = true,
    hud_scale = 1.0,
    hud_offset_y = 120,
    hud_alpha = 0.95,
    draw_every = 6,
    -- Hard cap on how many surfaces this mod will ever create.  The reference never destroys
    -- a surface, so a world comparison that fails to hold would otherwise make one per frame.
    surface_cap = 12,
    -- Font, alpha texture and material ids, read from the game's own globals the way the
    -- shipped Enemy HP mod does.  A Gui.text call whose font cannot be resolved is still
    -- accepted and renders nothing, so these are not optional decoration: passing the
    -- string 'core/performance_hud/debug' is what this mod used to do, and the screen
    -- stayed empty while the log said the paint had succeeded.
    font_rva = 0x3772268,
    alpha_rva = 0x3772EE8,
    material_ptr_rva = 0x37C5478,
    material_hash_off = 24,
}

-- The Hive Lord's key.  The same 64-bit value is the roster entity id, the datalibrary's
-- HealthComponentData key, and the descriptor's `type` field, which is why one constant
-- serves the roster reader and this.
local HIVE_LORD_HEX = 'cb077af7c7d965d4'
local HIVE_LORD = (function()
    local b = {}
    for i = 1, 16, 2 do b[#b + 1] = string.char(tonumber(HIVE_LORD_HEX:sub(i, i + 1), 16)) end
    return table.concat(b)
end)()
local HIVE_LORD_U64 = nil   -- set below, compared as two u32s so nothing goes through a double

local CFG_DIR_REL = '/Arrowhead/Helldivers2/hivelord_health.cfg'
-- Set by read_config when it had to create the file; reported once the log exists.
local CONFIG_WRITTEN = nil

-- The settings file is CREATED on first run, with the HUD on, so that installing the mod is
-- enough: nobody should have to be told to hand-write a file to see the bar.  An existing
-- file is never touched -- it is the user's, and silently rewriting settings is how a mod
-- loses trust.
local DEFAULT_CFG = [[
# Hive Lord Health - settings.  Created on first run; delete it to get these defaults back.
# Lines starting with # are ignored, and so is anything after a # on a value line.

# Draw the on-screen bar.  false = read only, nothing is ever drawn.
hud = true

# Seconds between reads of the health manager.
poll_seconds = 1

# HUD placement and look.
hud_scale = 1.0
hud_offset_y = 120
hud_alpha = 0.95

# Frames between HUD ticks (6 is about ten times a second at 60 fps).
draw_every = 6

# Frames to wait before the first read.
start_delay = 300
]]

local function read_config()
    local base = os.getenv('APPDATA')
    if not base then return end
    local path = base .. CFG_DIR_REL
    local f = io.open(path, 'r')
    if not f then
        -- Absent (first run): write the documented defaults out, so the file a user finds is
        -- the file that is actually in effect.  Failure is not fatal -- the defaults in C
        -- already apply -- so it is reported and ignored.
        local w = io.open(path, 'w')
        if w then
            w:write(DEFAULT_CFG)
            w:close()
            CONFIG_WRITTEN = path
        end
        return
    end
    local text = f:read('*a') or ''
    f:close()
    for line in text:gmatch('[^\r\n]+') do
        local k, v = line:match('^%s*([%w_]+)%s*=%s*([^#]+)')
        if k and C[k] ~= nil then
            v = v:gsub('%s+$', '')
            local n = tonumber(v)
            if type(C[k]) == 'boolean' then C[k] = (v == 'true' or v == '1' or v == 'yes')
            elseif n then C[k] = n end
        end
    end
end
read_config()

local function out_dir()
    local base = os.getenv('APPDATA')
    if base then return base .. '/Arrowhead/Helldivers2' end
    return '.'
end
local OUT = out_dir()
local LOG_PATH = OUT .. '/hivelord_health.log'
local STATUS_PATH = OUT .. '/hivelord_health_STATUS.txt'
local log_fail, log_lines, log_writes = 0, 0, 0
-- The log is appended for the whole play session; a rotation guard keeps it from growing
-- without bound (a live pair of sessions reached 634 KB, and the HP line is one per second
-- while the Hive Lord is being damaged).  Checked rarely, because it costs a file open.
local LOG_MAX_BYTES = 4 * 1024 * 1024

local function wf(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    local f = io.open(LOG_PATH, 'a')
    if not f then log_fail = log_fail + 1 return end
    f:write(os.date('%H:%M:%S '), msg, '\n')
    f:close()
    log_lines = log_lines + 1
    log_writes = log_writes + 1
    if log_writes % 256 == 0 then
        local probe = io.open(LOG_PATH, 'r')
        local size = probe and probe:seek('end') or nil
        if probe then probe:close() end
        if size and size > LOG_MAX_BYTES then
            os.remove(LOG_PATH .. '.old')
            os.rename(LOG_PATH, LOG_PATH .. '.old')
        end
    end
end

local M = { frame = 0, clock = 0, head = 'starting', notes = {}, last_line = nil,
            gui = nil, gui_world_key = nil, texts = nil, ink = nil, draw_key = nil,
            hm = nil, base = nil, polls = 0, best = nil }

local function write_status()
    local body = {
        'hivelord-health-v1.10.0 (read-only, build-pinned)',
        'loader api=' .. tostring(loader_api) .. ' version=' .. tostring(loader_version),
        'log: ' .. LOG_PATH .. ' lines=' .. log_lines .. ' failed=' .. log_fail,
        'CONCLUSION: ' .. M.head,
        '--- notes (newest last, capped at 20) ---',
    }
    for _, v in ipairs(M.notes) do body[#body + 1] = v end
    local f = io.open(STATUS_PATH .. '.new', 'w')
    if not f then return end
    f:write(table.concat(body, '\n'), '\n')
    f:close()
    os.remove(STATUS_PATH)
    os.rename(STATUS_PATH .. '.new', STATUS_PATH)
end

local function head(line)
    M.head = line
    write_status()
end

local function note(line)
    for _, v in ipairs(M.notes) do if v == line then return end end
    M.notes[#M.notes + 1] = line
    while #M.notes > 20 do table.remove(M.notes, 1) end
    write_status()
end

local function refuse(reason)
    wf('REFUSED %s', reason)
    head('REFUSED - ' .. reason)
    return { installed = false, reason = reason }
end

-- ------------------------------------------------------------------- ffi
local ok_ffi, ffi = pcall(require, 'ffi')
if not ok_ffi or type(ffi) ~= 'table' then
    return refuse('the ffi builtin is unavailable')
end
if not ffi.abi('64bit') then return refuse('this build is not 64-bit') end
if loader_api and loader_api < 1 then
    return refuse('Bingus Shared Loader API is ' .. tostring(loader_api) .. ', need >= 1')
end

ffi.cdef [[
    void *GetModuleHandleA(const char *);
    void *GetCurrentProcess(void);
    int   ReadProcessMemory(void *, const void *, void *, size_t, size_t *);
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
    } HL_HEALTH_MBI;
    size_t VirtualQuery(const void *, HL_HEALTH_MBI *, size_t);
]]
local kernel = ffi.load('kernel32')
local process = kernel.GetCurrentProcess()

local function module_base(name)
    local h = kernel.GetModuleHandleA(name)
    if h == nil then return nil end
    local v = tonumber(ffi.cast('uintptr_t', h))
    if not v or v < 65536 then return nil end
    return v
end

-- One reusable buffer, as the reference does.  Allocating an ffi buffer per read looked
-- harmless and was not: the health-table probe alone is up to 64 reads per descriptor and
-- the manager scan is up to 64 descriptors, so a mission entry meant thousands of
-- allocations per second -- a stutter, and needless GC pressure in the game's own Lua VM.
local READ_BUF = ffi.new('uint8_t[?]', 512)
local READ_GOT = ffi.new('size_t[1]')

local function read(addr, size)
    if type(addr) ~= 'number' or addr % 1 ~= 0 or addr < 65536 or addr >= 2 ^ 47 then
        return nil
    end
    if type(size) ~= 'number' or size % 1 ~= 0 or size < 1 or size > 512 then
        return nil
    end
    local ok = kernel.ReadProcessMemory(process, ffi.cast('void *', addr), READ_BUF, size,
        READ_GOT)
    if ok == 0 or tonumber(READ_GOT[0]) ~= size then return nil end
    return ffi.string(READ_BUF, size)
end

local function u32(s, o)
    if not s or o < 0 or o + 4 > #s then return nil end
    local a, b, c, d = s:byte(o + 1, o + 4)
    if not a then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function i32(s, o)
    local v = u32(s, o)
    if not v then return nil end
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

local function ptr_at(addr)
    local b = read(addr, 8)
    if not b then return nil end
    local lo = u32(b, 0)
    local hi = u32(b, 4)
    if hi >= 32768 then return nil end
    local v = hi * 4294967296 + lo
    if v < 65536 or v >= 2 ^ 47 then return nil end
    return v
end

-- --------------------------------------------------------------- build gate
-- Every address in C belongs to one build.  Identify it the way Enemy HP does -- the PE
-- headers of BOTH modules -- and refuse on anything else.  A wrong build here does not
-- produce an error, it produces a plausible number from an unrelated structure, so the
-- gate is the difference between a reading and an invention.
local BUILDS = {
    { name = '25480438',
      game = { 0x6AB3B43F, 0x4744000, 0xECDA6F },
      exe = { 0x6AB382E4, 0x39E8000, 0xE48B1D } },
}

local function pe_id(base)
    if not base then return nil end
    local d = read(base, 0x40)
    if not d or d:sub(1, 2) ~= 'MZ' then return nil end
    local lfanew = u32(d, 0x3C)
    if not lfanew then return nil end
    local h = read(base + lfanew, 0x60)
    if not h or h:sub(1, 4) ~= 'PE\0\0' then return nil end
    return { u32(h, 8), u32(h, 24 + 56), u32(h, 24 + 64) }
end

local function supported_build()
    local g, x = pe_id(M.base), pe_id(M.exe)
    if not g or not x then return nil, 'module headers unreadable' end
    for _, b in ipairs(BUILDS) do
        if g[1] == b.game[1] and g[2] == b.game[2] and g[3] == b.game[3]
            and x[1] == b.exe[1] and x[2] == b.exe[2] and x[3] == b.exe[3] then
            return b.name
        end
    end
    return nil, string.format('game.dll %X/%X/%X, exe %X/%X/%X',
        g[1], g[2], g[3], x[1], x[2], x[3])
end

-- ------------------------------------------------------------------ manager
-- The manager global is re-pointed when the world changes: the ship and a mission do not
-- share one manager.  Caching the pointers from an earlier poll therefore means reading an
-- allocation that no longer describes anything -- a live session showed entries=1 for the
-- eleven minutes spanning a mission change for exactly this reason, and the Hive Lord was
-- never seen.  Enemy HP re-reads the global inside every call; so does this.
local function find_manager()
    local hm = ptr_at(M.base + C.manager_rva)
    if not hm then return nil, 'the manager global is null' end
    -- Tracked on the address last SEEN, not on the last one parsed successfully: an empty
    -- manager is never cached, and the live case that matters is exactly "empty manager on
    -- the ship, then a real one in the mission".
    if M.hm_base and M.hm_base ~= hm then
        wf('MANAGER changed 0x%X -> 0x%X (a new world has its own manager)', M.hm_base, hm)
    end
    M.hm_base = hm
    local n = u32(read(hm + C.count_off, 4), 0)
    if not n then
        return nil, string.format('the entry count at hm+0x%X is unreadable', C.count_off)
    end
    if n > C.max_entries then
        return nil, string.format('implausible entry count %d at hm+0x%X', n, C.count_off)
    end
    -- An empty manager is a state, not an error: it is what the ship looks like before any
    -- unit is known.  Treating it as a refusal is how "nothing is loaded yet" came to look
    -- like "the offsets are wrong".
    if n == 0 then return nil, 'the manager holds no entries yet' end
    local arr = ptr_at(hm + C.arr_off)
    local recs = ptr_at(hm + C.recs_off)
    if not arr or not recs then return nil, 'the descriptor or record array is null' end
    M.hm = { base = hm, n = n, arr = arr, recs = recs }
    return M.hm
end

-- Every descriptor, as { j, type (raw 8 bytes), entity, unit, goid }.  Type is kept as raw
-- bytes so the 64-bit key never passes through a double.
local function descriptors(mgr)
    local out = {}
    for j = 0, mgr.n - 1 do
        local d = ptr_at(mgr.arr + j * 8)
        local db = d and read(d, C.descriptor_size)
        if db then
            out[#out + 1] = {
                j = j, type_le = db:sub(1, 8),
                entity = u32(db, 8), unit = u32(db, 12), goid = u32(db, 16),
                flags = u32(db, 20),
            }
        end
    end
    return out
end

-- Max health for a descriptor type, exactly as Enemy HP does it: an open-addressed table
-- of 1002 slots at t, each 16 bytes (u64 key, u32 index), and the record at
-- t + 0x3EA0 + index * 0x5650 whose first u32 is the maximum.
local function max_for_type(type_le)
    local net = ptr_at(M.base + C.network_rva)
    if not net then return nil, 'the network root is null' end
    local t = ptr_at(net + C.table_off)
    if not t then return nil, 'the health table pointer is null' end
    -- key % 1002, from the low 32 bits plus the high word scaled the way the reference does.
    local lo, hi = u32(type_le, 0), u32(type_le, 4)
    local start = (lo % C.table_slots + (hi % C.table_slots) * (4294967296 % C.table_slots))
        % C.table_slots
    for step = 0, 63 do
        local slot = t + ((start + step) % C.table_slots) * C.slot_size
        local b = read(slot, C.slot_size)
        if not b then break end
        local empty = true
        for i = 1, 8 do if b:byte(i) ~= 0 then empty = false break end end
        if b:sub(1, 8) == type_le then
            local idx = u32(b, 8)
            if idx and idx < C.table_slots then
                local rec = read(t + C.records_off + idx * C.health_stride, 4)
                local v = u32(rec, 0)
                if v and v > 0 and v < 10000000 then return v, 'table' end
            end
            return nil, 'the table slot has no usable record index'
        elseif empty then
            break
        end
    end
    return nil, 'the type is not in the health table'
end

-- --------------------------------------------------------------------- HUD
-- This is the FIRST mod's drawing call, put back deliberately:
--
--     Gui.text(gui, text, 'core/performance_hud/debug', size,
--              'core/performance_hud/debug', Vector2(x, y), Color(a, g, g, g))
--
-- That call rendered on screen in THIS build: the reported symptom was overlapping lines, and
-- only text that is visible can overlap.  Everything that replaced it -- font, material and
-- alpha ids read out of the game's globals, IdString64.from_hex, Gui.material plus
-- Material.set_scalar / set_vector2 / set_vector4 / set_texture, a Vector3 position -- is the
-- shipped reference mod's path.  That path is not wrong; it works for that mod.  But it is a
-- DIFFERENT engine API surface from the one this build has actually been seen to render, and
-- four crashes came from guessing at it.  The lesson is not "copy the reference"; it is
-- "change one thing at a time away from what already works".
--
-- What is kept from the crash work, because none of it adds engine calls: the surface is
-- never destroyed, at most two text objects exist per surface, and surfaces are capped.
local FONT_ID = 'core/performance_hud/debug'

local function clear_hud()
    local sr = _G.stingray
    if not (M.gui and M.texts) then
        M.draw_key = nil
        return
    end
    if type(sr.Gui.update_text) == 'function' then
        -- Blanked with a space, not destroyed.  Destroying is the operation whose handle came
        -- back as 0 in a live session, so it is the unproven one; a space plus a transparent
        -- colour hides the line without depending on it.
        for _, t in ipairs(M.texts) do
            pcall(sr.Gui.update_text, M.gui, t, ' ', FONT_ID, 12, FONT_ID,
                sr.Vector2(0, 0), sr.Color(0, 255, 255, 255))
        end
    else
        for _, t in ipairs(M.texts) do
            if type(sr.Gui.destroy_text) == 'function' then
                pcall(sr.Gui.destroy_text, M.gui, t)
            end
        end
        M.texts, M.text_creates = nil, 0
    end
    M.draw_key = nil
end

local function world_key(v) return tostring(v) end

local function live_world(worlds, key)
    if not key then return nil end
    for _, v in pairs(worlds or {}) do
        if world_key(v) == key then return v end
    end
    return nil
end

-- One line that says how far the HUD got.  Every exit from hud_tick is a silent return, so
-- "nothing is drawn" left no trace at all in a live log -- no error, no line, nothing to
-- act on.  Written only when the state text changes.
local function hud_state(text)
    if text ~= M.last_hud then
        M.last_hud = text
        wf('HUD_STATE %s', text)
    end
end

-- The real font / alpha / material ids, out of the game's own globals.  Read once and kept:
-- these are static for a build.  Returns nil plus a reason when they cannot be read, so the
-- caller can say WHICH font it ended up drawing with instead of guessing.
local function hash_hex(addr)
    local s = read(addr, 8)
    if not s then return nil end
    local lo, hi = u32(s, 0), u32(s, 4)
    if not lo or not hi or (lo == 0 and hi == 0) then return nil end
    return string.format('%08x%08x', hi, lo)
end

-- The minimum the proven call needs.  The reference's richer surface (Gui.material,
-- Material.set_*, IdString64) is deliberately NOT required here: requiring it is what turned
-- a working drawing into a crashing one, and nothing in the proven call uses it.
local function draw_api()
    local sr = _G.stingray
    if type(sr.Gui.text) ~= 'function' then return nil, 'Gui.text missing' end
    return true
end

local function paint(w, h, txt, sub)
    local sr = _G.stingray
    local okapi, why = draw_api()
    if not okapi then
        M.draw_key = nil
        return false, nil, 'refused (' .. tostring(why) .. ')'
    end
    local s = math.min(w / 1920, h / 1080) * C.hud_scale
    local x = w / 2 - 300 * s
    local y = C.hud_offset_y * s
    local a = math.floor(C.hud_alpha * 255)
    M.texts = M.texts or {}
    local function line(i, str, dy, size, grey)
        local pos = sr.Vector2(x, y + dy * s)          -- Vector2, as the first mod passed it
        local col = sr.Color(a, grey, grey, grey)      -- and its argument order
        if M.texts[i] and type(sr.Gui.update_text) == 'function' then
            return (pcall(sr.Gui.update_text, M.gui, M.texts[i], str, FONT_ID, size, FONT_ID,
                pos, col))
        end
        if M.texts[i] then
            -- No update_text on this build: destroy the tracked object and make another.  This
            -- path is capped below so it can never accumulate.
            if type(sr.Gui.destroy_text) == 'function' then
                pcall(sr.Gui.destroy_text, M.gui, M.texts[i])
            end
            M.texts[i] = nil
        end
        -- At most TWO text objects per surface, ever.  Unbounded creation is what exhausted
        -- the engine's GUI resources and took a live session down after a few minutes.
        if (M.text_creates or 0) >= 2 then return false end
        local ok, t = pcall(sr.Gui.text, M.gui, str, FONT_ID, size, FONT_ID, pos, col)
        if ok and t then
            M.texts[i] = t
            M.text_creates = (M.text_creates or 0) + 1
            return true
        end
        return false
    end
    local ok1 = line(1, txt, 0, 20, 255)
    local ok2 = line(2, sub, 22, 14, 190)
    M.draw_key = txt .. '\n' .. sub
    return (ok1 and ok2) and true or false, M.texts[1], 'debug-font'
end

local function hud_tick(world)
    if not C.hud then return hud_state('hud=off (set hud=true in hivelord_health.cfg)') end
    local sr = _G.stingray
    local App, World, Gui = sr.Application, sr.World, sr.Gui
    if type(App.worlds) ~= 'function' then return hud_state('no Application.worlds') end
    local worlds = App.worlds() or {}
    -- The world is NEVER destroyed.  The reference never calls World.destroy_gui: when the
    -- world changes it blanks the old surface and abandons it, then makes a new one.  This
    -- mod used to call destroy_gui with whatever handle it could find -- and entering a
    -- mission is exactly when the world list changes and that handle is stale, which took the
    -- game down on mission entry.  Blank, abandon, make another; never destroy.
    if M.gui and not live_world(worlds, M.gui_world_key) then
        clear_hud()
        M.gui, M.gui_world_key, M.ink, M.texts = nil, nil, nil, nil
    end
    if not M.gui then
        -- Prefer a world that is not the mod's own BY IDENTITY: a live log showed 11 worlds
        -- all rendering the same string, and App.main_world() rendered as nil at all, so a
        -- rendered comparison cannot tell them apart.  Identity is what the shipped reference
        -- mod uses, and its label does appear on screen.
        local pick
        for _, v in ipairs(worlds) do
            if v ~= world then pick = v break end
        end
        if not pick then
            for _, v in ipairs(worlds) do
                if world_key(v) ~= world_key(world) then pick = v break end
            end
        end
        -- A surface is created at most SURFACE_CAP times.  If the world identity comparison
        -- ever fails to hold, an uncapped version would make a new surface on every frame and
        -- exhaust the engine instead -- bounded creation is what makes this safe rather than
        -- merely careful.
        if pick and type(World.create_screen_gui) == 'function' then
            M.surfaces = (M.surfaces or 0) + 1
            if M.surfaces > C.surface_cap then
                if not M.surface_capped then
                    M.surface_capped = true
                    wf('HUD_SURFACE giving up after %d surfaces; drawing disabled', M.surfaces - 1)
                end
                return hud_state('drawing disabled: too many surfaces created')
            end
            local ok, g = pcall(World.create_screen_gui, pick, 'scale', 1, 1)
            if ok and g then
                M.gui, M.gui_world_key, M.ink, M.texts = g, world_key(pick), nil, nil
                M.text_creates = 0
                -- Logged ONCE, by wf rather than hud_state: a state line here would
                -- alternate with the per-frame outcome line, defeat the de-duplication and
                -- write a line every frame (3054 lines in two minutes in a live session).
                wf('HUD_SURFACE created on %s (worlds=%d identity=%s, surface #%d)',
                    world_key(pick), #worlds, tostring(pick ~= world), M.surfaces)
            end
        end
    end
    if not M.gui then
        return hud_state(string.format('no surface: worlds=%d create_screen_gui=%s',
            #worlds, type(World.create_screen_gui)))
    end
    if type(Gui.resolution) ~= 'function' then return hud_state('no Gui.resolution') end
    local w, h = Gui.resolution()
    if type(w) ~= 'number' or type(h) ~= 'number' or w <= 0 or h <= 0 then
        return hud_state('bad resolution ' .. tostring(w) .. 'x' .. tostring(h))
    end
    local r = M.best
    if not r then
        clear_hud()
        return hud_state(string.format('surface ready (%dx%d) but no reading yet', w, h))
    end
    local txt = string.format('HIVE LORD  %d / %d', r.hp or -1, r.max or -1)
    local sub = string.format('exact, from the health manager (entry %d of %d)',
        r.j or -1, M.hm and M.hm.n or 0)
    if txt .. '\n' .. sub ~= M.draw_key then
        local ok, id, source = paint(w, h, txt, sub)
        hud_state(string.format('painted=%s id=%s font=%s text="%s"', tostring(ok),
            tostring(id), tostring(source), txt))
    end
end

-- ------------------------------------------------------------------- poll
local function poll()
    M.polls = M.polls + 1

    local mgr, why = find_manager()
    if not mgr then
        local line = 'MANAGER not available: ' .. tostring(why)
        if line ~= M.last_line then
            M.last_line = line
            wf('%s', line)
        end
        M.best = nil
        head('no reading yet: ' .. tostring(why))
        return
    end

    local list = descriptors(mgr)
    -- The Hive Lord's descriptor carries its type key.  Also record every descriptor whose
    -- maximum is 150000, so the log proves which entry is the Hive Lord even if the key
    -- assumption is wrong -- a wrong key must not look like "the Hive Lord is absent".
    --
    -- The by-max scan is capped AND rate-limited: each lookup is up to 64 reads, so scanning
    -- every descriptor on every poll was thousands of reads per second for a diagnostic that
    -- only matters when the key did not match.
    local MAX_SCAN = 64
    local hit = nil
    for _, d in ipairs(list) do
        if d.type_le == HIVE_LORD then hit = d break end
    end
    local by_max = {}
    if not hit and M.clock >= (M.next_by_max or 0) then
        M.next_by_max = M.clock + C.by_max_seconds
        for i, d in ipairs(list) do
            if i > MAX_SCAN then break end
            local mx = max_for_type(d.type_le)
            if mx == 150000 then by_max[#by_max + 1] = d end
        end
    end

    -- State, once every DIAG_SECONDS and only when it changes.  Without this a manager that
    -- holds one entry and a table pointer that cannot be read look identical: both show up
    -- as "no entry", and they need opposite fixes.
    if M.clock >= (M.next_diag or 0) then
        M.next_diag = M.clock + C.diag_seconds
        local net = ptr_at(M.base + C.network_rva)
        local t = net and ptr_at(net + C.table_off)
        local parts = {}
        for i, d in ipairs(list) do
            if i > 8 then break end
            parts[#parts + 1] = string.format('%d:%08x%08x e=%s g=%s', d.j,
                u32(d.type_le, 4) or 0, u32(d.type_le, 0) or 0,
                tostring(d.entity), tostring(d.goid))
        end
        local slot0 = t and read(t, 8)
        local hex0 = slot0 and (slot0:gsub('.', function(c)
            return string.format('%02x', c:byte())
        end)) or 'unreadable'
        local hl_max, hl_src = max_for_type(HIVE_LORD)
        local hl = hl_max and string.format('%s (%s)', tostring(hl_max), tostring(hl_src))
            or ('not found: ' .. tostring(hl_src))
        -- The three asset ids, reported even with the HUD switched off.  Whether they are
        -- readable decides whether drawing is safe at all, and that has to be answerable
        -- without risking a crash to find out.  Read here rather than through asset_ids()
        -- so the answer does not depend on the drawing path having run.
        local idf = hash_hex(M.base + C.font_rva)
        local ida = hash_hex(M.base + C.alpha_rva)
        local idmp = ptr_at(M.base + C.material_ptr_rva)
        local idm = idmp and hash_hex(idmp + C.material_hash_off) or nil
        local ids_text = string.format('font=%s mat=%s alpha=%s', tostring(idf),
            tostring(idm), tostring(ida))
        local diag = string.format(
            'DIAG hm=0x%X entries=%d arr=0x%X recs=0x%X net=0x%X table=0x%X slot0=%s '
            .. 'hive_lord_max=%s ids[%s]',
            mgr.base, mgr.n, mgr.arr, mgr.recs, net or 0, t or 0, hex0, hl, ids_text)
        local desc = 'DIAG_DESC ' .. (#parts > 0 and table.concat(parts, ' ') or 'none')
        -- Written when the STRUCTURE changes, not on a timer.  `entries` fluctuates every
        -- few seconds as units come and go, so a timer produced 149 lines in 13 minutes
        -- that were almost all noise -- and the lines that mattered (a manager swap, a
        -- table that stopped resolving) were buried in it.  These four values are the ones
        -- that change what a reader should do next.
        local diag_key = string.format('%X|%X|%s|%s', mgr.base, t or 0,
            tostring(hl_max), parts[1] or 'none')
        if diag_key ~= M.last_diag then
            M.last_diag = diag_key
            wf('%s', diag)
            wf('%s', desc)
        end
    end

    -- A reading is HELD briefly when the entry is momentarily absent.  A live log showed the
    -- HP line and a NO_ENTRY line alternating inside one second -- the manager's entry list
    -- churns (87..101 entries) and the Hive Lord's descriptor is briefly not among them while
    -- it is being registered.  Blanking on the first miss makes the bar flicker; holding
    -- forever would be a stale reading.  A couple of seconds is neither.
    if not hit and M.best and (M.clock - (M.best_at or -1e9)) <= C.hold_seconds then
        return
    end

    if not hit then
        local names = {}
        for i, d in ipairs(by_max) do
            if i <= 4 then
                local lo = u32(d.type_le, 0) or 0
                local hi = u32(d.type_le, 4) or 0
                names[#names + 1] = string.format('%08x%08x(entity=%s goid=%s)',
                    hi, lo, tostring(d.entity), tostring(d.goid))
            end
        end
        local line = string.format(
            'NO_ENTRY entries=%d max150000=%d%s', mgr.n, #by_max,
            #names > 0 and (' [' .. table.concat(names, ' ') .. ']') or '')
        if line ~= M.last_line then
            M.last_line = line
            wf('%s', line)
        end
        M.best = nil
        head(string.format(
            'no Hive Lord entry in the health manager (%d entries, %d with max 150000)%s',
            mgr.n, #by_max,
            #by_max > 0 and ' -- the 150000 holder is logged as NO_ENTRY' or ''))
        return
    end

    local hp = i32(read(mgr.recs + hit.j * C.record_stride + C.hp_off, 4), 0)
    local mx, src = max_for_type(hit.type_le)
    local line = string.format('HP goid=%s entity=%s unit=%s j=%d hp=%s max=%s (%s)',
        tostring(hit.goid), tostring(hit.entity), tostring(hit.unit), hit.j,
        tostring(hp), tostring(mx), tostring(src))
    M.best = { hp = hp, max = mx or 150000, j = hit.j, goid = hit.goid }
    M.best_at = M.clock
    if line ~= M.last_line then
        M.last_line = line
        wf('%s', line)
        head(string.format('Hive Lord %s / %s exact (entry %d of %d)%s',
            tostring(hp), tostring(mx or 150000), hit.j, mgr.n,
            src == 'table' and '' or ' -- maximum not found in the table, 150000 assumed'))
    end
end

local function update(dt, ...)
    M.frame = M.frame + 1
    local step = type(dt) == 'number' and dt or 0.016667
    if step < 0 then step = 0 elseif step > 0.25 then step = 0.25 end
    M.clock = M.clock + step
    local world = nil
    if _G.stingray and _G.stingray.Application
        and type(_G.stingray.Application.main_world) == 'function' then
        world = _G.stingray.Application.main_world()
    end
    if M.frame > C.start_delay and M.clock >= (M.next_poll or 0) then
        M.next_poll = M.clock + C.poll_seconds
        local ok, err = pcall(poll)
        if not ok then
            wf('POLL_ERROR %s', tostring(err))
            head('POLL_ERROR: ' .. tostring(err))
        end
    end
    if M.frame % C.draw_every == 0 then
        local ok, err = pcall(hud_tick, world)
        if not ok then
            wf('HUD_ERROR %s', tostring(err))
        end
    end
end

-- ------------------------------------------------------------------ install
if not rawget(_G, 'stingray') then
    return refuse('the stingray API table is missing')
end
M.base = module_base('game.dll')
M.exe = module_base('helldivers2.exe')
if not M.base then return refuse('game.dll is not loaded') end
if not M.exe then return refuse('helldivers2.exe is not loaded') end

local build, why = supported_build()
if not build then
    return refuse('unsupported game build: ' .. tostring(why)
        .. ' -- the offsets belong to build 25480438 only')
end
wf('BUILD %s verified from the PE headers of game.dll and helldivers2.exe', build)
if CONFIG_WRITTEN then
    wf('CONFIG created with defaults (hud=%s): %s', tostring(C.hud), CONFIG_WRITTEN)
else
    wf('CONFIG in effect: hud=%s (edit %s%s to change)', tostring(C.hud),
        tostring(os.getenv('APPDATA') or '?'), CFG_DIR_REL)
end
wf('ARMED manager_rva=0x%X network_rva=0x%X table_off=0x%X', C.manager_rva, C.network_rva,
    C.table_off)
head('armed on build ' .. build .. '; waiting for a mission')

local old = rawget(_G, 'update')
rawset(_G, 'update', function(...)
    local ok, err = pcall(update, ...)
    if not ok then
        wf('LUA_ERROR %s', tostring(err))
        head('LUA_ERROR: ' .. tostring(err))
    end
    if type(old) == 'function' then return old(...) end
end)

local stop = rawget(_G, 'shutdown')
rawset(_G, 'shutdown', function(...)
    pcall(clear_hud)
    if type(stop) == 'function' then return stop(...) end
end)

write_status()
return { installed = true, build = build }
