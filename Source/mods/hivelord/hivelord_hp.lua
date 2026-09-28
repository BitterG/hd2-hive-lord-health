-- HD2-Addon: mods/hivelord/hivelord_hp
-- Hive Lord live health reader.  READ-ONLY: no write API of any kind is called.
--
-- This is the deliverable.  It does everything the diagnostic probe does and then
-- goes further: instead of needing a second game session to freeze the health
-- field indices, it *derives* them at runtime and reports what it derived.
--
-- WHY SELF-CALIBRATION
--   The engine exposes health as a positional field array
--   (GameSession.game_object_field_batched).  The shipped DRIVER HUD mod proves
--   the mechanism -- for the Bastion hull, index 15 is the maximum and index 30
--   the current value -- but the indices are per-type, so they cannot be copied.
--   What IS known offline is the Hive Lord's arithmetic (byte-exact parse of the
--   plaintext generated_entities.dl_bin, see work/hivelord/HIVE_LORD_HEALTH.md):
--
--     main health 150000
--     38 damage zones: (150000,0)x9 (15000,35000)x12 (20000,35000)x1
--                      (10000,0)x2 (5000,0)x14
--
--   So the entity can be *identified* by that arithmetic alone, and the maximum
--   health field is the field holding 150000.  Which of the 150000-valued fields
--   is the live main pool is settled by damage: only the current-value field
--   moves.  Every observation is logged, so the indices can be frozen to
--   constants afterwards regardless of what the heuristic decides.
--
-- SAFETY RULES INHERITED FROM THE EARLIER CRASH
--   An earlier probe resource walked the Network table and invoked every member
--   to see what it returned.  That crashed the game twice.  Calling an engine
--   function with the wrong arguments is a native access violation, not a Lua
--   error, and pcall cannot catch it.  Therefore every engine member this file
--   touches is listed in ALLOWED_MEMBERS below and is individually proven by
--   DRIVER HUD 1.2.1.  Risky calls are written to the log before they run, and
--   the object sweep keeps a cursor on disk so a crash costs one object, not the
--   whole session.

local function call(f, ...)
    if type(f) ~= 'function' then return nil end
    local ok, a, b = pcall(f, ...)
    if ok then return a, b end
    return nil, b
end

-- Read the loader's own version marker before anything else, so every log and the
-- status file can carry it: every support question then arrives with the
-- environment already in it.
local loader = rawget(_G, 'CowboyBingusModLoader')
local loader_api = type(loader) == 'table' and tonumber(loader.api) or nil
local loader_version = type(loader) == 'table' and tonumber(loader.version) or nil

-- ---------------------------------------------------------------- configuration
local C = {
    debug = true,
    hud = true,              -- on by default: the reading is decoded and labelled now
    sweep = true,
    max_id = 32766,
    sweep_per_frame = 128,
    probe_per_frame = 2,
    probe_budget_ms = 8,
    probe_delay = 300,       -- frames; the census must finish first anyway
    in_mission_only = true,
    watch_seconds = 0.25,
    read_seconds = 1,        -- how often a full HP row is logged
    scoreboard_seconds = 15, -- how often the ranked candidate list is written
    -- A target that appears and dies between two censuses is never read at all, and
    -- "no candidate was found" then looks exactly like "no Hive Lord was present".
    -- That is what happened in the ninth run: a Hive Lord was fought and killed with
    -- the reader running, 901 objects were probed, and none of them was ever the
    -- target.  A `game_object_exists` walk of 1..max_id is a few hundred cheap native
    -- calls per second, so while nothing has been identified the census simply keeps
    -- running at full rate -- looking IS the job.
    resweep_seconds = 10,    -- full re-census interval while nothing is identified
    resweep_backoff_cap = 4, -- and at most 4x that once a target is being watched
    probe_cycle_seconds = 2, -- re-read the census ids this often, not once per census
    shape_dump_min = 20,     -- dump the full array of any object this large
    log_max_bytes = 16 * 1024 * 1024, -- the 2 MB cap was destroying the SAMPLE history
    main_150k_hint = 150000,
    zone_run_min = 10,       -- minimum contiguous magic run to call it the zone array
    try_field_names = false, -- probe game_object_field with name guesses (lookup only)
    hud_offset_y = 150,
    hud_scale = 1,
    hud_alpha = 0.85,
    hud_bar_width = 24,
}
local dir = call(os.getenv, 'APPDATA')
if dir and io and io.open then
    local f = io.open(dir .. '/Arrowhead/Helldivers2/hivelord_hp.cfg', 'r')
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
-- The log is opened, appended and closed per line.  A persistent handle plus
-- flush() was observed in a live session to leave a 0-byte log while the STATUS
-- file kept working: if the write is buffered and the flush raises, dropping the
-- handle discards the line silently.  Per-line append cannot lose anything, and
-- the volume is bounded by design (the per-frame flood was fixed separately).
local outdir, log_path
local log_ok, log_fail, log_bytes = 0, 0, 0
if io and io.open then
    local la = call(os.getenv, 'LOCALAPPDATA')
    local tp = call(os.getenv, 'TEMP')
    local cands = {}
    if dir then cands[#cands + 1] = dir .. '/Arrowhead/Helldivers2' end
    if la then cands[#cands + 1] = la .. '/CowboyBingus/Helldivers2/Logs' end
    if tp then cands[#cands + 1] = tp end
    cands[#cands + 1] = '.'
    for _, d in ipairs(cands) do
        local probe = io.open(d .. '/hivelord_hp.log', 'a')
        if probe then
            outdir = d
            log_path = d .. '/hivelord_hp.log'
            pcall(function() probe:close() end)
            break
        end
    end
end

local function w(line)
    if not log_path or not io or not io.open then return end
    log_bytes = log_bytes + #line + 1
    local f = io.open(log_path, 'a')
    if not f then log_fail = log_fail + 1; return end
    local ok = pcall(function() f:write(line, '\n'); f:close() end)
    if not ok then
        pcall(function() f:close() end)
        log_fail = log_fail + 1
        return
    end
    log_ok = log_ok + 1
    -- Keep the log bounded; a long session otherwise grows it without limit.
    if log_bytes > C.log_max_bytes then
        log_bytes = 0
        local t = io.open(log_path, 'w')
        if t then
            t:write('--- log truncated (exceeded ', C.log_max_bytes, ' bytes) ---\n')
            t:close()
        end
    end
end
local function wf(fmt, ...) w(string.format(fmt, ...)) end
wf('LOG_OPEN path=%s', tostring(log_path))

-- STATUS is a *status* file, not a second log.  The first live session grew it to
-- 760 KB because every progress line was appended and the whole list rewritten on
-- each update -- O(n^2) writes, and useless to read.  Now there is one replaceable
-- conclusion line plus a bounded, deduplicated set of recent notes.
--
-- Writing goes through write_durable: io.open(path,'w') truncates immediately, and
-- a live session was caught with a 0-byte STATUS.txt precisely because it sampled
-- the file between the truncate and the write.  A crash in that window loses
-- everything, so the new content is staged in .new first.
local function write_durable(path, content)
    if not io or not io.open then return false end
    -- Some hosts expose a reduced `os`.  Fall back to a plain write rather than
    -- erroring: a missing staging step is far better than no status file at all.
    if type(os.rename) ~= 'function' or type(os.remove) ~= 'function' then
        local f = io.open(path, 'w')
        if not f then return false end
        local ok = pcall(function() f:write(content); f:close() end)
        if not ok then pcall(function() f:close() end); return false end
        return true
    end
    local tmp = path .. '.new'
    local f = io.open(tmp, 'w')
    if not f then return false end
    local ok = pcall(function() f:write(content); f:close() end)
    if not ok then pcall(function() f:close() end); return false end
    -- os.rename does not overwrite on Windows, so remove the old file first; the
    -- replacement already exists as .new, so this cannot lose the new content.
    pcall(os.remove, path)
    local rok = pcall(os.rename, tmp, path)
    return rok and true or false
end

local STATUS_HEAD = 'starting'
local STATUS_NOTES, STATUS_NOTE_CAP = {}, 24

-- The loader may manage the game's shared LuaJIT code cache (loader v18+).  Its state
-- belongs here because it changes how this mod's own timings should be read: a cache
-- flush discards every compiled trace, so a hitch during one is the environment, not this
-- mod.  The loader's `version` field is not a reliable signal -- the v18 source still
-- reports version = 17 -- so presence of CowboyBingusModLoader.jit is what is checked.
local function jit_state()
    local j = type(loader) == 'table' and loader.jit or nil
    if type(j) ~= 'table' then return 'not exposed (loader before v18, or discovery only)' end
    if not j.managed then return 'unmanaged (' .. tostring(j.reason) .. ')' end
    return string.format('managed %s KB / %s traces, flushes=%s growth=%s watcher=%s',
        tostring(j.mcode_kb), tostring(j.traces), tostring(j.flushes),
        tostring(j.growths), tostring(j.watcher))
end

local function write_status()
    if not outdir then return end
    local parts = {
        'hivelord-hp-v1.2.0 (read-only)',
        'loader api=' .. tostring(loader_api) .. ' version=' .. tostring(loader_version),
        'loader jit: ' .. jit_state(),
        -- The log's own health goes in the status file: a live session produced a
        -- 0-byte log while STATUS worked, and nothing anywhere said so.
        'log: ' .. tostring(log_path) .. ' lines=' .. log_ok .. ' failed=' .. log_fail,
        'CONCLUSION: ' .. STATUS_HEAD,
        '--- recent notes (newest last, capped at ' .. STATUS_NOTE_CAP .. ') ---',
    }
    for _, v in ipairs(STATUS_NOTES) do parts[#parts + 1] = v end
    write_durable(outdir .. '/hivelord_hp_STATUS.txt', table.concat(parts, '\n') .. '\n')
end

local function status_head(line)
    STATUS_HEAD = line
    write_status()
end

local function status(line)
    -- Deduplicate against every note, not just the previous one: the diagnostics can
    -- re-run as the sample grows, so the same census line legitimately arrives again
    -- later and a repeated note would push a distinct one out of the cap.
    for _, v in ipairs(STATUS_NOTES) do
        if v == line then return end
    end
    STATUS_NOTES[#STATUS_NOTES + 1] = line
    while #STATUS_NOTES > STATUS_NOTE_CAP do table.remove(STATUS_NOTES, 1) end
    write_status()
end

-- ------------------------------------------------------------------ env gates
-- These run *after* logging is set up, on purpose.  Returning before logging
-- means a mod that is loaded but cannot work produces no output at all -- the
-- user sees "nothing happened" and there is no evidence to diagnose it with.
-- Every refusal now names itself in hivelord_hp_STATUS.txt.
local function refuse(reason)
    wf('REFUSED %s', reason)
    status_head('REFUSED - ' .. reason)
    return { installed = false, reason = reason }
end

local sr = rawget(_G, 'stingray')
if not sr then return refuse('no stingray global (engine Lua API unavailable)') end
if rawget(_G, '__HIVELORD_HP_INSTALLED') then
    wf('ALREADY_LOADED')
    status('already loaded in this session; nothing to do')
    return { installed = true, reason = 'already loaded' }
end

local App, Net, GS, World = sr.Application, sr.Network, sr.GameSession, sr.World
local Gui = sr.Gui
local V2, V3, Color = sr.Vector2, sr.Vector3, sr.Color
if type(GS) ~= 'table' and type(GS) ~= 'userdata' then
    return refuse('stingray.GameSession is unavailable at load time')
end
if loader_api and loader_api < 1 then
    return refuse('Bingus Shared Loader API is ' .. tostring(loader_api) .. ', need >= 1')
end
if type(rawget(_G, 'update')) ~= 'function' then
    return refuse('no global update() to chain; loaded out of order or too early')
end

-- ------------------------------------------------------- engine namespaces
-- Discovered by disassembling the game's OWN Lua resources
-- (work/gamelua/*.lua.main, see work/hivelord/gamelua_api.py).  The game's entity
-- vector-field script reads exactly these:
--
--     local World              = stingray.World
--     local EntityManager      = stingray.EntityManager
--     local DataComponent      = stingray.DataComponent
--     local TransformComponent = stingray.TransformComponent
--     local Script             = stingray.Script
--     ...
--     local list = <component>:instances_with_tag_in_entity(a, b)
--     local v    = <component>:get_property(instance, 'duration')
--     stingray.components.<ComponentName> = { entity_data = ... }
--
-- Whether any of that helps a health reader depends on what those tables actually
-- contain, and until now the log could not answer even that.  Listing their keys
-- is pure pairs() iteration -- no engine call is made, so it cannot fault, and it
-- is the one piece of reconnaissance that is worth having on every single run.
local function list_keys(label, t, cap)
    if t == nil then
        wf('NS %s = nil', label)
        return 0
    end
    if type(t) ~= 'table' then
        wf('NS %s = %s', label, type(t))
        return 0
    end
    local ks = {}
    for k in pairs(t) do
        ks[#ks + 1] = tostring(k)
        if #ks >= 2000 then break end
    end
    table.sort(ks)
    wf('NS %s keys=%d [%s]', label, #ks, table.concat(ks, ' ', 1, math.min(#ks, cap)))
    return #ks
end

local function dump_namespaces()
    local n = 0
    for _, name in ipairs({ 'EntityManager', 'components', 'DataComponent',
                            'TransformComponent', 'Script', 'Unit', 'World',
                            'UnitUtils', 'Entity', 'Vector3', 'Matrix4x4' }) do
        n = n + list_keys('stingray.' .. name, sr[name], 160)
    end
    local top = {}
    for k in pairs(sr) do top[#top + 1] = tostring(k) end
    table.sort(top)
    wf('NS stingray keys=%d [%s]', #top, table.concat(top, ' '))
    status(string.format('engine namespaces listed (%d entries across 11 tables)', n))
end

dump_namespaces()

local STATE_NAME = 'hivelord_hp_state.txt'
local function save_state(tbl)
    if not outdir or not io or not io.open then return end
    local f = io.open(outdir .. '/' .. STATE_NAME, 'w')
    if not f then return end
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do f:write(string.format('%s=%s\n', k, tostring(tbl[k]))) end
    f:close()
end
local function load_state()
    local t = {}
    if not outdir or not io or not io.open then return t end
    local f = io.open(outdir .. '/' .. STATE_NAME, 'r')
    if not f then return t end
    for l in f:lines() do
        local k, v = l:match('^([%w_]+)=(.*)$')
        if k then t[k] = tonumber(v) or v end
    end
    f:close()
    return t
end

-- ------------------------------------------------------------- field helpers
local MAGIC = { 150000, 35000, 15000, 10000, 5000, 20000, 8000, 800, 2500 }
local MAGIC_SET = {}
for _, v in ipairs(MAGIC) do MAGIC_SET[v] = true end

local function dense_count(f)
    if type(f) ~= 'table' then return -1 end
    local n = 0
    while f[n + 1] ~= nil do
        n = n + 1
        if n > 8192 then break end
    end
    return n
end

local function fingerprint(f)
    local found, distinct = {}, 0
    local n = dense_count(f)
    for i = 1, n do
        local v = f[i]
        if type(v) == 'number' and MAGIC_SET[v] then
            if not found[v] then found[v] = 0; distinct = distinct + 1 end
            found[v] = found[v] + 1
        end
    end
    return n, distinct, found
end

local function found_text(found)
    local p = {}
    for _, m in ipairs(MAGIC) do if found[m] then p[#p + 1] = m .. 'x' .. found[m] end end
    return table.concat(p, ',')
end

local MIN_150K = 6
local MIN_DISTINCT = 5
local WEAK_DISTINCT = 3    -- anything this interesting gets dumped even if unproven
local WEAK_CAP = 64        -- cap on weak dumps so the folder stays readable

-- INSURANCE FOR THE ONE-SHOT RUN.
-- The strong gate encodes a guess: that the Hive Lord's network field array
-- mirrors the entity definition and therefore carries ten 150000s.  That guess is
-- not proven -- the shipped DRIVER HUD reads a hull whose array is only 35 fields
-- with a single max/current pair and no zone strand at all.  If the Hive Lord's
-- array is like that, the strong gate never fires and the session would be wasted.
-- So every object holding even one 150000 is dumped in full, and the sweep logs a
-- ranked scoreboard even when nothing matches.  A wrong guess then costs nothing:
-- the answer is already on disk.

-- ============================================================ self-calibration
-- Pure function of one field array plus the observed history, so it is fully
-- testable offline.  Returns a table describing what it decided and why.

-- ---------------------------------------------------- the client-synced value
-- What a *client* can actually know about a Hive Lord's health, established by
-- measurement (FINDINGS.md sections 22/23) rather than assumed:
--
--   * the object's 46 networked fields hold no absolute health.  Followed through a
--     whole fight and its death: not one field went to zero, and the only
--     damage-shaped field read 61/63 at the instant the entity was destroyed.
--   * the client's only runtime health type is `SyncedHealthComponent`, which the
--     game's own typelib declares as FOUR BYTES.  150000 plus 38 damage zones cannot
--     fit in four bytes, which is why four full in-game passes and an independent
--     13 GB external scan found only the read-only archetype table.
--
-- So the number shown is the synchronised value, converted to an approximate HP and
-- labelled as such on screen.  It is quantised to six bits on the wire: exactly
-- k/63 for some k in 0..63.  That is a property, so the field is FOUND rather than
-- hardcoded as an index -- in every session observed it was the only field in the
-- array whose value was ever exactly k/63.
--
-- The tolerance admits float32 representation error only (observed below 3e-8).
-- A value that merely falls in [0,1] cannot pass: the nearest k/63 is up to
-- 1/126 = 0.0079 away.
local function is_k63(v)
    if type(v) ~= 'number' or v < 0 or v > 1 then return nil end
    if v == 1 then return 63 end
    local k = math.floor(v * 63 + 0.5)
    if k < 0 or k > 63 then return nil end
    if math.abs(v - k / 63) <= 1e-6 then return k end
    return nil
end

-- Field values are no longer all integers: the synchronised value is a fraction, so
-- `%d` would raise on it ("number has no integer representation" in Lua 5.3+).  The
-- live engine is LuaJIT, where %d on a float silently truncates -- which is exactly why
-- this class of bug keeps surviving a live run and only surfaces offline.  The same
-- mistake was already fixed once for a fractional config value; render numbers through
-- one helper so it cannot come back a third time.
local function num(v)
    if type(v) ~= 'number' then return tostring(v) end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format('%d', v) end
    return string.format('%.6g', v)
end

-- The damage mask: a 14-bit counter that only ever falls.  Observed going
-- 16383 (0x3FFF = 2^14-1) -> 16243 -> 16227 -> ... -> 5383 across one fight without
-- ever rising, while the object itself never went away -- so it tracks damage to the
-- entity, not the entity's lifetime.  Fourteen is also exactly the fin count in the
-- offline zone parse (boss_l/r_leg + spine0..5_l/r_leg).  Found by its all-ones first
-- observation rather than by index, and optional: without it the HUD says less.
local function mask_of(f, hist)
    for i = 1, #f do
        local h = hist and hist[i]
        if h and h.first == 16383 and type(f[i]) == 'number' then return i end
    end
    return nil
end

local function calibrate(f, hist, prev)
    local n, distinct, found = fingerprint(f)
    local out = { fields = n, distinct = distinct, magic = found_text(found) }
    if n <= 0 then
        out.identified = false
        return out
    end

    -- The zone array is the longest run of contiguous indices that all hold one of
    -- the known zone maxima.  Computed BEFORE the identification gate on purpose:
    -- otherwise an array that fails identification reports nothing about its shape,
    -- which is precisely the case worth having evidence for.  It is NOT required for
    -- identification, because on the real object it never appears.
    local best_a, best_b, best_len = nil, nil, 0
    local a = nil
    for i = 1, n + 1 do
        local v = i <= n and f[i] or nil
        local is_magic = type(v) == 'number' and MAGIC_SET[v] ~= nil
        if is_magic and a == nil then a = i end
        if not is_magic and a ~= nil then
            local len = i - a
            if len > best_len then best_a, best_b, best_len = a, i - 1, len end
            a = nil
        end
    end
    if best_len >= C.zone_run_min then
        out.zone_a, out.zone_b, out.zone_len = best_a, best_b, best_len
    end

    -- Identification, redone from measurement.
    --
    -- The previous gate required >= 5 distinct magic values and >= 6 fields holding
    -- 150000, mirroring the archetype table's 38 zones (nine of them 150000).  The
    -- networked object never looks like that -- it has ONE 150000 and ONE distinct
    -- magic value -- so that gate never fired in any live session and the HUD never
    -- drew at all.
    --
    -- What it does have, in every session observed, are two independent properties:
    -- one field equal to 150000 (the maximum), and one field holding a six-bit k/63
    -- fraction (the synchronised current value).  Requiring both is what keeps this
    -- from matching an unrelated object that merely happens to hold a 150000.
    --
    -- A previously confirmed index is reused first.  k = 0 is excluded from the
    -- *search* below -- every padding field is 0 and 0 is also k/63, so a zero field
    -- is evidence of nothing -- but 0 is a perfectly good later reading (the pool
    -- emptied), and re-deriving from scratch would drop the identification at exactly
    -- the moment the Hive Lord dies.
    local max_idx, sync_idx, sync_k
    if prev and prev.sync_idx then
        local k = is_k63(f[prev.sync_idx])
        if k then sync_idx, sync_k = prev.sync_idx, k end
    end
    for i = 1, n do
        if f[i] == 150000 and not max_idx then max_idx = i end
        if not sync_idx then
            local k = is_k63(f[i])
            if k and k > 0 then sync_idx, sync_k = i, k end
        end
    end
    out.max_idx, out.sync_idx, out.sync_k = max_idx, sync_idx, sync_k
    if not max_idx or not sync_idx then
        out.identified = false
        out.why = (not max_idx) and 'no field holds the 150000 maximum'
            or 'no field holds a six-bit k/63 synchronised value'
        return out
    end
    out.identified = true

    -- Maximum health.  Known offline to be 150000 and confirmed live by the field
    -- that holds exactly that value; the constant is used for the arithmetic so a
    -- momentarily odd field read cannot corrupt the bar.
    out.max_health = C.main_150k_hint
    out.max_health_known = C.main_150k_hint
    out.max_field_value = f[max_idx]

    -- Current health: the synchronised fraction, converted.  Deliberately NOT a
    -- field holding an absolute value -- no such field exists client-side, and the
    -- previous "largest drop among fields that ever held 150000" heuristic was
    -- chasing one.  Six bits is coarse by construction: one step is
    -- 150000/63 = 2381 HP, and the HUD says so instead of hiding it.
    out.sync_value = f[sync_idx]
    out.cur_idx = sync_idx
    out.cur_health = math.floor(sync_k / 63 * out.max_health + 0.5)
    out.cur_step = math.floor(out.max_health / 63 + 0.5)
    out.cur_quantised = true
    out.provisional = false
    out.client_synced = true
    out.mask_idx = mask_of(f, hist)
    out.mask_value = out.mask_idx and f[out.mask_idx] or nil
    out.moved = {}
    local moved_keys = {}
    for i in pairs(hist or {}) do
        if type(i) == 'number' then moved_keys[#moved_keys + 1] = i end
    end
    table.sort(moved_keys)
    for _, i in ipairs(moved_keys) do
        local h = hist[i]
        if h.first and h.value and h.value ~= h.first then
            out.moved[#out.moved + 1] = string.format('%d:%s->%s', i, num(h.first), num(h.value))
        end
    end
    out.moved_text = table.concat(out.moved, ' ')
    return out
end

-- --------------------------------------------------------- object identification
local M = {
    frame = 0, clock = 0,
    session_key = nil, was_in_session = nil, peer_scalar = nil,
    census = {}, sweeping = false, sweep_id = 1, new_census = {},
    probed = {}, probe_list = {}, probe_index = 1, probes = 0, next_resweep = 0,
    known = {}, diag_done = false, drained_logged = false,
    best = {}, weak = {}, weak_list = {}, dumped_w = 0, samples = 0,
    goid = nil, watch_goid = nil, watch_score = nil,
    hist = {}, hist_count = 0, last = {}, cal = nil,
    next_watch = 0, next_read = 0, owned_seen = 0,
    gui = nil, gui_world = nil, gui_world_key = nil, draw_ids = {}, draw_key = nil,
}

local function land_census()
    if not outdir then return end
    -- The field count is the column that matters: the first live run swept every
    -- id and reported no candidates, and without this column there is no way to
    -- tell "the read returned nothing" from "the read worked and held no known
    -- health value".  Those two need completely different fixes.
    local parts = {
        '# goid census; fields = game_object_field_batched result length',
        '# id\tfields\tdistinct_magic\tmagic_counts',
    }
    local ids = {}
    for id in pairs(M.census) do ids[#ids + 1] = id end
    table.sort(ids)
    local with_fields, max_fields = 0, 0
    for _, id in ipairs(ids) do
        local k = M.known and M.known[id]
        if k then
            with_fields = with_fields + 1
            if k.fields > max_fields then max_fields = k.fields end
            parts[#parts + 1] = string.format('%d\t%d\t%d\t%s', id, k.fields, k.distinct, k.magic or '')
        else
            parts[#parts + 1] = string.format('%d\t-1\t-1\t', id)
        end
    end
    write_durable(outdir .. '/hivelord_hp_census.txt', table.concat(parts, '\n') .. '\n')
    -- Also put the census in the log, so pasting one file is enough to diagnose.
    local sample = {}
    for i = 1, math.min(#ids, 64) do sample[#sample + 1] = tostring(ids[i]) end
    wf('CENSUS_IDS n=%d sample=[%s]', #ids, table.concat(sample, ' '))
    wf('CENSUS_FIELDS objects=%d with_fields=%d max_fields=%d', #ids, with_fields, max_fields)
    status(string.format('census: %d ids, %d returned fields (max %d fields)',
        #ids, with_fields, max_fields))
end

local function start_census()
    M.sweep_id = 1
    M.sweeping = true
    M.new_census = {}
    wf('SWEEP start max_id=%d', C.max_id)
end

-- Full field array for one object, so a wrong identification guess still leaves
-- usable data on disk.
local function dump_array(id, f, prefix, index)
    if not outdir or not io or not io.open then return end
    local n = dense_count(f)
    if n <= 0 then return end
    local _, distinct, found = fingerprint(f)
    local ff = io.open(string.format('%s/hivelord_hp_%s%d_goid%d.txt', outdir, prefix, index, id), 'w')
    if not ff then return end
    ff:write(string.format('# goid=%d fields=%d distinct_magic=%d [%s]\n',
        id, n, distinct, found_text(found)))
    for i = 1, n do
        local v = f[i]
        local tv = type(v)
        local sv
        if tv == 'number' then
            sv = (v == math.floor(v) and math.abs(v) < 1e15)
                and string.format('%d', v) or string.format('%.6f', v)
        elseif tv == 'table' then
            local m = dense_count(v)
            local parts = {}
            for k = 1, math.min(m, 24) do parts[#parts + 1] = tostring(v[k]) end
            sv = string.format('<table %d> %s', m, table.concat(parts, ' '))
        else
            sv = tostring(v)
        end
        ff:write(string.format('%d\t%s\t%s\n', i, tv, sv))
    end
    ff:close()
end

local function note_candidate(id, cnt, distinct, found)
    local w = found[150000] or 0
    -- Idempotent per id.  The probe now re-reads the whole census continuously, and an
    -- append-every-time version then listed the same object twelve times AND made
    -- M.noted grow on every pass -- which fired the scoreboard on every pass too (196
    -- SCOREBOARD lines in a 37-second fixture run).  A candidate is an event the first
    -- time it is seen, or when its shape actually changes.
    local slot
    for i, c in ipairs(M.best) do
        if c.id == id then
            slot = i
            break
        end
    end
    if slot then
        local c = M.best[slot]
        if c.n150k == w and c.distinct == distinct and c.fields == cnt then
            return
        end
        c.fields, c.distinct, c.n150k, c.magic = cnt, distinct, w, found_text(found)
    else
        M.best[#M.best + 1] = { id = id, fields = cnt, distinct = distinct,
                                n150k = w, magic = found_text(found) }
    end
    M.noted = (M.noted or 0) + 1
    table.sort(M.best, function(a, b)
        if a.n150k ~= b.n150k then return a.n150k > b.n150k end
        if a.distinct ~= b.distinct then return a.distinct > b.distinct end
        return a.id < b.id
    end)
    while #M.best > 12 do table.remove(M.best) end
    if not M.weak[id] and found[150000] then
        M.weak[id] = true
        if #M.weak_list < WEAK_CAP then M.weak_list[#M.weak_list + 1] = id end
    end
end

local function report_scoreboard(why)
    wf('SCOREBOARD %s candidates=%d', why, #M.best)
    for i, c in ipairs(M.best) do
        wf('SCOREBOARD #%d goid=%d fields=%d distinct=%d n150k=%d [%s]',
            i, c.id, c.fields, c.distinct, c.n150k, c.magic)
    end
end

-- Sorted list of census ids not yet probed.  Declared before its caller because
-- `local function` only binds from the point of declaration onwards.
-- `all` exists for the periodic re-probe.  Without it the queue is empty after the
-- first pass -- every id is in M.probed -- so a re-queue would do nothing at all and the
-- probe would still be one-shot, which is the whole problem being fixed here.  Re-reading
-- an object is cheap and it is what makes a short-lived target visible; reading each
-- object exactly once is what made the ninth run's Hive Lord invisible.
local function build_probe_list(all)
    local list = {}
    for id in pairs(M.census) do
        if all or not M.probed[id] then list[#list + 1] = id end
    end
    table.sort(list)
    return list
end

-- One-shot DIAGNOSTIC block, run after the first census.
--
-- It exists because the first live run was *ambiguous*: the sweep completed over
-- 380 real objects and reported no candidates, but the log could not say whether
-- game_object_field_batched had returned nothing at all or had returned arrays
-- containing no known health value.  Those two need opposite fixes, so the next
-- run must not be able to end ambiguously.  Every call here is proven by the
-- shipped DRIVER HUD mod.
local function run_diagnostics(session, peer)
    -- 1. Is the entity API alive in this build?  DRIVER HUD proves this exact type
    --    has 27 fields, so a non-empty answer means the API works.
    local info = call(Net.object_info, 'rHVbvgIu')
    local nf = -1
    if type(info) == 'table' and info.fields then nf = dense_count(info.fields) end
    wf('DIAG object_info(rHVbvgIu).fields=%d', nf)

    -- 2. What does the local peer own?  Every read DRIVER HUD relies on is on an
    --    object from this list.  If the field read only works there, the sweep
    --    must start here rather than at the bottom of the id space.
    local owned = call(GS.objects_owned_by, session, peer)
    local owned_ids = {}
    if type(owned) == 'table' then
        for _, id in ipairs(owned) do
            if type(id) == 'number' then owned_ids[#owned_ids + 1] = id end
        end
    end
    table.sort(owned_ids)
    local txt = {}
    for i = 1, math.min(#owned_ids, 24) do txt[#txt + 1] = tostring(owned_ids[i]) end
    wf('DIAG owned n=%d ids=[%s]', #owned_ids, table.concat(txt, ' '))

    -- 3. The decisive test: field counts on owned objects, dumped in full.
    local owned_ok, owned_zero = 0, 0
    for i = 1, math.min(#owned_ids, 8) do
        local id = owned_ids[i]
        if call(GS.game_object_exists, session, id) == true then
            local f = call(GS.game_object_field_batched, session, id, {})
            local cnt, distinct, found = fingerprint(f)
            wf('DIAG owned_probe goid=%d fields=%d distinct=%d [%s]',
                id, cnt, distinct, found_text(found))
            if cnt and cnt > 0 then
                owned_ok = owned_ok + 1
                dump_array(id, f, 'owned', owned_ok)
            else
                owned_zero = owned_zero + 1
            end
        end
    end
    wf('DIAG owned_field_reads ok=%d empty=%d', owned_ok, owned_zero)

    -- 4. How many census objects returned anything at all, and how long were they.
    local n0, n1_8, n9_20, n21_40, n41, magic_any = 0, 0, 0, 0, 0, 0
    local census_n = 0
    for id in pairs(M.census) do
        census_n = census_n + 1
        local k = M.known[id]
        local n = k and k.fields or 0
        if n <= 0 then n0 = n0 + 1
        elseif n <= 8 then n1_8 = n1_8 + 1
        elseif n <= 20 then n9_20 = n9_20 + 1
        elseif n <= 40 then n21_40 = n21_40 + 1
        else n41 = n41 + 1 end
        if k and k.distinct and k.distinct > 0 then magic_any = magic_any + 1 end
    end
    wf('DIAG fields_hist empty=%d f1_8=%d f9_20=%d f21_40=%d f41plus=%d any_magic=%d',
        n0, n1_8, n9_20, n21_40, n41, magic_any)

    -- 4b. Did anything carry the Hive Lord's 150000?  "some object had a known
    --     health value" and "some object had 150000" are very different: the first
    --     can be satisfied by an arbitrary 800, and only the second says the Hive
    --     Lord was actually present.  A live session reported
    --     "5 object(s) held a known health value" where all five were 800x1 --
    --     i.e. no Hive Lord in that mission at all.
    local n150k = 0
    for id in pairs(M.census) do
        local k = M.known[id]
        if k and k.magic and k.magic:find('150000', 1, true) then n150k = n150k + 1 end
    end
    wf('DIAG objects_with_150000=%d', n150k)

    -- 5. The id space is partitioned: the live census sat in blocks 171..1501,
    --    4096..4196, 8192..8332 and 12288..12333, i.e. id>>12 buckets 0,1,2,3.
    --    Logging the shape makes that structure visible instead of guesswork.
    local buckets, ks = {}, {}
    for id in pairs(M.census) do
        local b = math.floor(id / 4096)
        if not buckets[b] then buckets[b] = 0; ks[#ks + 1] = b end
        buckets[b] = buckets[b] + 1
    end
    table.sort(ks)
    local parts = {}
    for _, b in ipairs(ks) do parts[#parts + 1] = string.format('%d:%d', b, buckets[b]) end
    wf('CENSUS_BUCKETS id>>12 counts=[%s]', table.concat(parts, ' '))

    -- 6. A verdict, so the next run cannot end ambiguously again.  This is the
    --    whole point of the diagnostic block: "the API is dead", "the API lives
    --    but will not read these objects" and "the read works" need different
    --    fixes and must be distinguishable from STATUS alone.
    local verdict
    -- Every verdict carries how much of the census was readable at all.  "No 150000 was
    -- read" is NOT "no Hive Lord was present", and this block used to say the second.  A
    -- live log with 1141 of 1162 objects returning no fields at all announced "no Hive Lord
    -- was present in this mission" -- a claim the read cannot support, and exactly the
    -- conflation this project keeps having to undo.  The blind fraction qualifies a
    -- positive finding too, so it belongs in all of them.
    local blind = string.format('%d of %d census object(s) returned no fields', n0, census_n)
    if nf <= 0 then
        verdict = 'the entity API is not answering at all (object_info empty) -- use HiveLord-HP-MemScan'
    elseif owned_ok == 0 and magic_any == 0 then
        verdict = string.format(
            'the entity field read returns nothing usable: object_info works (%d fields) but owned reads ok=%d/%d and no census object held a known health value; %s -- game_object_field_batched does not expose these objects, use HiveLord-HP-MemScan',
            nf, owned_ok, #owned_ids, blind)
    elseif magic_any == 0 then
        verdict = string.format(
            'field reads work (owned ok=%d) but no census object held a known health value; %s -- most likely no Hive Lord was present, but the blind fraction is the caveat and not a proof of absence',
            owned_ok, blind)
    elseif n150k == 0 then
        verdict = string.format(
            'health-like values found on %d object(s) but none held 150000; %s -- so this is "not read", not proven absent: if a Hive Lord is on screen, damage it and send the log',
            magic_any, blind)
    else
        verdict = string.format(
            'field reads work and %d object(s) held 150000; %s -- see WATCH_FIELDS/SCOREBOARD for which field is the live value',
            n150k, blind)
    end
    wf('VERDICT %s', verdict)
    -- Always a note so it survives.  The conclusion line belongs to whatever answers the
    -- user's question, and with the HUD on that question is "what is on my screen" -- the
    -- verdict used to own the head unconditionally, which silently overwrote the HUD state
    -- message and left the status file still unable to explain an empty screen.  With the
    -- HUD off, the verdict is the answer and takes the head.
    status('VERDICT: ' .. verdict)
    if not C.hud then
        status_head('VERDICT: ' .. verdict)
    else
        -- Say so out loud.  Without this the rule is invisible: a reader who expects the
        -- verdict on the conclusion line has no way to tell it was deliberately withheld,
        -- and the test for the rule could not observe it either.
        wf('VERDICT_HEAD withheld: the HUD is on, so the conclusion answers the screen '
            .. '(the verdict is in the notes above)')
    end
    status(string.format('DIAG: API fields=%d, owned=%d (%d read ok), census any_magic=%d',
        nf, #owned_ids, owned_ok, magic_any))
    M.diag_done = true
end

local function advance_census(session)
    local done = 0
    while M.sweeping and done < C.sweep_per_frame and M.sweep_id <= C.max_id do
        local id = M.sweep_id
        M.sweep_id = M.sweep_id + 1
        done = done + 1
        if call(GS.game_object_exists, session, id) == true then
            -- Merge into the accumulated set rather than replacing it: a later
            -- census taken after the world emptied (2 objects) must not erase the
            -- 174 ids seen during the mission.
            M.census[id] = true
            M.new_census[id] = true
        end
    end
    if M.sweeping and M.sweep_id > C.max_id then
        M.sweeping = false
        local n = 0
        for _ in pairs(M.census) do n = n + 1 end
        wf('SWEEP done objects=%d', n)
        status(string.format('census: %d ids accumulated', n))
        -- Deliberately no land_census() here: at this point nothing has been probed,
        -- so the file would be all -1 and would bury the useful snapshot written
        -- later by the diagnostics.
        -- Build the probe queue from the census.  Game object ids are sparse (the
        -- first live log showed 4096 and 8192 in one world), so walking the whole
        -- 1..32766 space in order spends minutes probing ids that do not exist and
        -- may never reach the interesting ones.
        M.probe_list, M.probe_index = build_probe_list(), 1
        M.probes_at_census = M.probes
        wf('PROBE queued=%d ids (walking the census, not 1..%d)', #M.probe_list, C.max_id)
        -- Back off when a census finds nothing new.  The second live session ran
        -- 10901 completed sweeps, almost all of them rediscovering the same
        -- objects; that is pure wasted native calls.
        local added = n - (M.prev_census_n or 0)
        M.prev_census_n = n
        -- Back off only once a target has been IDENTIFIED, not merely weakly watched.  A
        -- weak candidate is a guess, not a find: the ninth run's failure was precisely
        -- that a weak watch made the reader look confident while the real target came and
        -- went unread.  While the identity is still unknown, widening the census interval
        -- is the one behaviour that cannot possibly help.
        if added <= 0 and M.goid then
            M.resweep_backoff = math.min((M.resweep_backoff or 1) * 2, C.resweep_backoff_cap)
        else
            M.resweep_backoff = 1
        end
        wf('RESWEEP new_ids=%d backoff=%dx interval=%ds', added,
            M.resweep_backoff, C.resweep_seconds * M.resweep_backoff)
    end
end

-- Complete per-object shape, on disk, bounded, and independent of the log's size cap.
-- The ninth run left only twenty SAMPLE lines as shape evidence -- the counter caps them
-- at 20 -- and a log cap had already eaten the rest, so the one question that mattered
-- afterwards ("was the target readable at all, and what did it look like?") could not be
-- answered from the log.  This file is rewritten every probe cycle and always complete.
local function land_samples()
    if not outdir then return end
    local ids = {}
    for id in pairs(M.known) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {
        '# per-object shape, rewritten every probe cycle (complete, not sampled)',
        '# id\tfields\tdistinct_magic\tmagic_counts',
    }
    for _, id in ipairs(ids) do
        local k = M.known[id]
        parts[#parts + 1] = string.format('%d\t%d\t%d\t%s', id, k.fields, k.distinct, k.magic)
    end
    write_durable(outdir .. '/hivelord_hp_samples.txt', table.concat(parts, '\n') .. '\n')
end

-- ------------------------------------------------- change tracking for candidates
-- Identification needs a value that behaves like damage, and for a candidate that holds
-- the 150000 maximum but no k/63 fraction, the encoding of that value is exactly what is
-- unknown.  Guessing it is how a plausible-looking model gets certified; instead, record
-- WHICH field moves.  The Hive Lord's health must be one of them, and the player damaging
-- it is the experiment.
--
-- A field is logged at most TRACK_MOVES times.  Position and rotation fields change on
-- every pass, and an unbounded version of this produced 22438 identical scoreboard lines
-- in one live session -- the log flood this project has already paid for once.
--
-- Defined here, after `M`: a function defined before `local M` sees a global named M, and
-- the first version of this was placed with the constants above -- which made every probe
-- raise on `M.cand_prev` and broke identification entirely.
local TRACK_MOVES = 3

local function field_snapshot(f)
    local n = dense_count(f)
    local out = {}
    for i = 1, n do
        local v = f[i]
        local t = type(v)
        if t == 'number' then out[i] = v
        elseif t == 'boolean' then out[i] = v and 'true' or 'false'
        else out[i] = tostring(v) end
    end
    return out, n
end

-- Records the movement of every still-interesting field of a 150000-holding candidate.
local function track_candidate(id, f)
    M.cand_prev = M.cand_prev or {}
    M.cand_moves = M.cand_moves or {}
    local vals, n = field_snapshot(f)
    local prev = M.cand_prev[id]
    if prev then
        local moves, shown = M.cand_moves[id] or {}, {}
        for i = 1, math.max(#prev, n) do
            if prev[i] ~= vals[i] then
                moves[i] = (moves[i] or 0) + 1
                if moves[i] <= TRACK_MOVES and #shown < 12 then
                    shown[#shown + 1] = string.format('%d:%s->%s', i,
                        tostring(prev[i]), tostring(vals[i]))
                end
            end
        end
        M.cand_moves[id] = moves
        if #shown > 0 then
            wf('CAND_MOVED goid=%d fields=%d moved=[%s]', id, n, table.concat(shown, ' '))
        end
    end
    M.cand_prev[id] = vals
end

local function advance_probe(session)
    local deadline = os.clock() + (C.probe_budget_ms / 1000)
    local n = 0
    while n < C.probe_per_frame and M.probe_index <= #M.probe_list do
        local id = M.probe_list[M.probe_index]
        M.probe_index = M.probe_index + 1
        n = n + 1
        M.probes = M.probes + 1
        save_state({ goid = M.goid or 0, probe_cursor = id })
        if call(GS.game_object_exists, session, id) == true then
            local f = call(GS.game_object_field_batched, session, id, {})
            local cnt, distinct, found = fingerprint(f)
            -- Only mark it done when the read produced fields.  An object that
            -- exists but has no fields yet is left in the queue so the next census
            -- retries it -- otherwise anything that was still initialising at the
            -- first pass is never looked at again.
            if cnt and cnt > 0 then M.probed[id] = true end
            -- A candidate holding the 150000 maximum is tracked for field movement even
            -- while it is unproven.  This is the instrument that answers "which field is
            -- the health" without assuming an encoding.
            if found[150000] then track_candidate(id, f) end
            if cnt and cnt >= 0 then
                M.known[id] = { fields = cnt, distinct = distinct, magic = found_text(found) }
            end
            -- Sample a few objects unconditionally.  The first live run produced no
            -- SCAN lines at all, which left it unknown whether
            -- game_object_field_batched works here or simply never saw a magic
            -- value; a raw field count answers that either way.
            if cnt and cnt > 0 and M.samples < 20 then
                M.samples = M.samples + 1
                wf('SAMPLE goid=%d fields=%d distinct=%d [%s]', id, cnt, distinct, found_text(found))
            end
            -- Any object big enough to be the target is dumped in full, whether or not
            -- it holds a value we recognise.  Requiring a known magic value to dump is
            -- how a target whose array look changed between missions stays invisible:
            -- the ninth run probed 901 objects, saw none of them, and there was nothing
            -- on disk to say what the large ones actually contained.
            if cnt and cnt >= C.shape_dump_min then
                M.shape_dumped = M.shape_dumped or {}
                if not M.shape_dumped[id] then
                    M.shape_dumped[id] = true
                    M.dumped_s = (M.dumped_s or 0) + 1
                    dump_array(id, f, 'shape', M.dumped_s)
                    wf('SHAPE_DUMP goid=%d fields=%d distinct=%d [%s]',
                        id, cnt, distinct, found_text(found))
                end
            end
            -- Threshold is "any known maximum at all", not "two kinds".  An array
            -- holding only 150000s is exactly the shape a sparse Hive Lord would
            -- have, and requiring two kinds would silently drop it.
            if cnt and cnt > 0 and distinct >= 1 then
                wf('SCAN goid=%d fields=%d distinct=%d [%s]', id, cnt, distinct, found_text(found))
                note_candidate(id, cnt, distinct, found)
                -- Dump anything holding a 150000 as it is found, so the data
                -- survives even if this session never sees a strong match.
                if found[150000] and not (M.weak_dumped and M.weak_dumped[id]) then
                    M.weak_dumped = M.weak_dumped or {}
                    M.weak_dumped[id] = true
                    M.dumped_w = (M.dumped_w or 0) + 1
                    dump_array(id, f, 'weak', M.dumped_w)
                    -- Watch the best weak candidate even when the strong gate never
                    -- fires.  The live run's goid 714 (field 17 = 150000) was found
                    -- and dumped but never watched, so nothing was learned about
                    -- which field carries the *current* value -- the one remaining
                    -- question.  Prefer more 150000s, then more fields.
                    -- A candidate that passes the MEASURED identification is the Hive
                    -- Lord, whatever its magic-value score.  Ranking by score alone
                    -- picked the wrong object -- a decoy holding two 150000s outscored
                    -- the real one (1*1000+46) at 2*1000+40 -- so the real object was
                    -- only ever dumped, never watched, and the reader learned nothing
                    -- about it.  Identification decides; the score only breaks ties
                    -- among candidates that are not identified.
                    local c0 = calibrate(f, M.hist)
                    if c0.identified then
                        M.goid, M.watch_goid, M.watch_score = id, nil, nil
                        M.cal = c0
                        wf('HIVE_LORD goid=%d fields=%d identified by measurement: max_idx=%s '
                            .. 'sync_idx=%s k=%s mask_idx=%s',
                            id, cnt, tostring(c0.max_idx), tostring(c0.sync_idx),
                            tostring(c0.sync_k), tostring(c0.mask_idx))
                        status_head(string.format(
                            'Hive Lord identified: goid=%d fields=%d (150000 max at field %s, '
                            .. '%s/63 synced at field %s)', id, cnt, tostring(c0.max_idx),
                            tostring(c0.sync_k), tostring(c0.sync_idx)))
                        save_state({ goid = id, probe_cursor = id })
                        -- Deliberately NO break.  Breaking here abandons the rest of the
                        -- queue, and because `drained` is then never true the continuous
                        -- re-probe below never fires either -- the probe silently becomes
                        -- one-shot again, and every object after the target is never read.
                        -- Probing the remainder costs a few native calls per frame.
                    end
                    local score = (found[150000] or 0) * 1000 + cnt
                    if score > (M.watch_score or -1) then
                        M.watch_score = score
                        M.watch_goid = id
                        M.hist, M.hist_count, M.cal = {}, 0, nil
                        wf('WEAK_WATCH_SET goid=%d fields=%d n150k=%d (best so far)',
                            id, cnt, found[150000] or 0)
                    end
                end
            end
            if cnt and cnt > 0 and distinct >= MIN_DISTINCT
                and (found[150000] or 0) >= MIN_150K then
                M.goid = id
                wf('HIVE_LORD goid=%d fields=%d distinct=%d [%s]', id, cnt, distinct,
                    found_text(found))
                status_head(string.format('Hive Lord found: goid=%d fields=%d [%s]',
                    id, cnt, found_text(found)))
                save_state({ goid = id, probe_cursor = id })
                -- Break rather than return: the diagnostic block at the tail must
                -- still run.  Returning here is how the first attempt at these
                -- diagnostics ended up silently skipped whenever the target was
                -- found, which is precisely when they are least expendable.
                break
            end
        end
        if os.clock() > deadline then break end
    end
    -- Log the ranked candidate list periodically, not only when the queue drains:
    -- the whole point of the list is that it is already on disk if the strong gate
    -- never fires.
    local drained = M.probe_index > #M.probe_list
    if drained and not M.drained_logged then
        M.drained_logged = true
        wf('PROBE_DRAINED probed=%d candidates=%d', M.probes, #M.best)
    end
    -- Keep the read loop running.  A one-shot queue means a target that appears after
    -- the queue drained is only noticed at the next census; re-queueing the census ids
    -- keeps probing continuous, so a short-lived object is read within seconds of
    -- appearing instead of possibly never.  Gating on `drained` alone is not enough --
    -- anything that stops the walk early leaves the index below the end and the queue is
    -- abandoned -- so a stalled queue is re-queued too, on the same timer.
    local stalled = M.probe_index == (M.last_probe_index or -1)
    M.last_probe_index = M.probe_index
    if (drained or stalled) and #M.probe_list > 0
        and M.clock >= (M.next_probe_cycle or 0) then
        M.next_probe_cycle = M.clock + C.probe_cycle_seconds
        -- Deliberately NOT resetting M.drained_logged: PROBE_DRAINED is informational and
        -- reports once per session.  The per-cycle line is PROBE_REQUEUE, and it carries
        -- a counter so consecutive lines differ -- an identical line repeated every cycle
        -- is exactly the 22438-line flood this log already suffered once.
        M.probe_list, M.probe_index = build_probe_list(true), 1
        M.probes_at_census = M.probes
        local known = 0
        for _ in pairs(M.known) do known = known + 1 end
        wf('PROBE_REQUEUE queued=%d objects_with_fields=%d cycles=%d',
            #M.probe_list, known, (M.probe_cycles or 0) + 1)
        M.probe_cycles = (M.probe_cycles or 0) + 1
        land_samples()
    end
    -- Diagnostics must not run on a tiny sample.  A live session produced
    -- "no census object held a known health value" after examining only about
    -- eight of 163 objects, and that verdict was then frozen -- exactly the kind
    -- of premature conclusion that sends the next round down the wrong path.
    -- Wait until most of the queue has actually been walked, and re-evaluate as
    -- the sample grows.
    local examined = M.probes - (M.probes_at_census or 0)
    local target = math.max(24, math.floor(#M.probe_list * 0.8))
    if (#M.probe_list > 0 and examined >= target) or drained or M.goid ~= nil then
        M.diag_wanted = true
    end
    -- Interval-gated, plus immediate on a newly noted candidate.  `drained` stays
    -- true once true, so gating on it alone logged the same line every frame --
    -- 22438 identical SCOREBOARD lines in one live session.  But an interval alone
    -- is worse in the case that matters: the best candidates are often found last,
    -- and waiting 15 s for the next tick can mean never reporting them at all.
    local grew = (M.noted or 0) > (M.reported_noted or 0)
    if grew or M.clock >= (M.next_scoreboard or 0) then
        M.next_scoreboard = M.clock + C.scoreboard_seconds
        if grew then M.reported_noted = M.noted end
        report_scoreboard(grew and 'new_candidate'
            or (drained and 'queue_drained' or 'progress'))
        if not M.goid then
            local top = M.best[1]
            status(string.format('no strong Hive Lord match yet; probed %d; top candidate %s; %d array(s) dumped',
                M.probes, top and string.format('goid=%d fields=%d [%s]', top.id, top.fields, top.magic)
                    or 'none', M.dumped_w or 0))
        end
    end
end

-- -------------------------------------------------------------- the live read
-- Every numeric field is tracked, not just the 150000 ones.  The live run found an
-- object (goid 714) whose field 17 is 150000 but which the strong gate never
-- accepted, so nothing was ever watched -- and the one thing that would settle
-- where the *current* value lives is "which field moves when it takes damage".
-- Tracking every numeric field answers that without needing any gate to fire.
local HIST_MAX = 512
local function seed_history(f)
    local n = dense_count(f)
    for i = 1, n do
        if type(f[i]) == 'number' then
            local h = M.hist[i]
            if not h then
                if M.hist_count >= HIST_MAX then break end
                M.hist_count = M.hist_count + 1
                M.hist[i] = { first = f[i], value = f[i], moved = false }
            end
        end
    end
end

local function read_once(session)
    local id = M.goid or M.watch_goid
    if not id then return end
    if call(GS.game_object_exists, session, id) ~= true then
        wf('LOST goid=%d', id)
        if M.goid == id then M.goid = nil end
        if M.watch_goid == id then M.watch_goid = nil end
        M.hist, M.hist_count, M.cal = {}, 0, nil
        return
    end
    local f = call(GS.game_object_field_batched, session, id, {})
    local n = dense_count(f)
    if n <= 0 then return end
    seed_history(f)
    for i, h in pairs(M.hist) do
        local v = f[i]
        if type(v) == 'number' then
            h.value = v
            if v ~= h.first then h.moved = true end
        end
    end
    M.last = f
    -- Calibrate whichever object is being watched, and promote a weak candidate that
    -- passes the MEASURED identification to the pinned object.
    --
    -- This is the second half of the same mistake: the strong gate required five
    -- distinct magic values and six 150000s, mirroring the archetype table's 38 zones.
    -- The real Hive Lord carries ONE 150000 and ONE distinct magic value, so the gate
    -- never fired, M.goid was never set, calibration never ran for that object, and
    -- the HUD never drew a single frame in any live session.  The measured test -- a
    -- 150000 maximum AND a six-bit k/63 fraction in the same array -- is stricter than
    -- the old gate in the way that matters, so passing it is grounds for promotion.
    local c = calibrate(f, M.hist, M.cal)
    M.cal = c
    if c.identified and M.goid ~= id then
        M.goid, M.watch_goid, M.watch_score = id, nil, nil
        wf('HIVE_LORD goid=%s fields=%d identified by measurement: max_idx=%s sync_idx=%s '
            .. 'k=%s mask_idx=%s mask=%s',
            tostring(id), c.fields, tostring(c.max_idx), tostring(c.sync_idx),
            tostring(c.sync_k), tostring(c.mask_idx), tostring(c.mask_value))
        status_head(string.format(
            'Hive Lord identified: goid=%s fields=%d (150000 max at field %s, %s/63 synced at field %s)',
            tostring(id), c.fields, tostring(c.max_idx), tostring(c.sync_k),
            tostring(c.sync_idx)))
        save_state({ goid = id, probe_cursor = id })
    end
end

-- The field-level delta: indices whose value has moved since the first snapshot,
-- largest absolute change first.  When the Hive Lord takes damage this names the
-- current-value field outright, which is the one fact the whole reader needs.
local function deltas_text(limit)
    local d = {}
    for i, h in pairs(M.hist) do
        if h.moved and type(h.value) == 'number' and type(h.first) == 'number' then
            d[#d + 1] = { i = i, first = h.first, value = h.value,
                          delta = h.value - h.first }
        end
    end
    table.sort(d, function(a, b)
        return math.abs(a.delta) > math.abs(b.delta)
    end)
    local parts = {}
    for k = 1, math.min(#d, limit or 12) do
        parts[#parts + 1] = string.format('%d:%s->%s(%+g)', d[k].i,
            tostring(d[k].first), tostring(d[k].value), d[k].delta)
    end
    return #d, table.concat(parts, ' ')
end

local function report()
    local id = M.goid or M.watch_goid
    local nmoved, dtext = deltas_text(12)
    if M.goid then
        local c = M.cal
        if not c then return end
        wf('HP identified=%s fields=%d max_idx=%s max=%s sync_idx=%s sync_k=%s cur=%s step=%d mask_idx=%s mask=%s client_synced=%s moved=[%s] zone=[%s..%s]',
            tostring(c.identified), c.fields, tostring(c.max_idx), tostring(c.max_health),
            tostring(c.sync_idx), tostring(c.sync_k), tostring(c.cur_health),
            c.cur_step or 0, tostring(c.mask_idx), tostring(c.mask_value),
            tostring(c.client_synced), c.moved_text or '',
            tostring(c.zone_a), tostring(c.zone_b))
    end
    -- Logged for weak candidates too, which is where the real answer came from.
    wf('WATCH_FIELDS goid=%s strong=%s fields=%d changed=%d [%s]',
        tostring(id), tostring(M.goid ~= nil),
        dense_count(M.last), nmoved, dtext)
    if M.goid then
        local c = M.cal
        if c and c.identified then
            status_head(string.format(
                'HP sync=%s/%s [wire %s/63 at field %s | 150000 max at field %s | mask %s at field %s] '
                .. '-- client-synced value, one step = %d HP; the exact HP is host-side and not in this process',
                tostring(c.cur_health), tostring(c.max_health), tostring(c.sync_k),
                tostring(c.sync_idx), tostring(c.max_idx), tostring(c.mask_value),
                tostring(c.mask_idx), c.cur_step or 0))
        end
    elseif nmoved > 0 then
        -- Even without a strong match, a moving field tells us what we came for.
        status_head(string.format(
            'WEAK WATCH goid=%s: %d field(s) changed since first seen: %s',
            tostring(id), nmoved, dtext))
    elseif id then
        status_head(string.format(
            'WEAK WATCH goid=%s: watching, no field has changed yet -- damage the Hive Lord',
            tostring(id)))
    end
end

-- The HUD is text-only on purpose: a filled bar needs a material resource, which
-- this package deliberately does not ship.  Off by default.
-- Engine handles are FRESH wrappers on every call.  The live log already taught this
-- project that: `Net.game_session()` and `App.main_world()` compare unequal to themselves
-- across calls, which reset the sweep every frame and stopped it ever passing id 903.  So
-- a world is identified by what it renders as, never by identity, and the wrapper is
-- looked up again whenever one is actually needed.  These must be defined before
-- surface_reset, which uses them.
local function world_key(v) return tostring(v) end

local function live_world(worlds, key)
    if not key then return nil end
    for _, v in pairs(worlds or {}) do
        if world_key(v) == key then return v end
    end
    return nil
end

local function remember(kind, id) M.draw_ids[#M.draw_ids + 1] = { kind, id } end
local function clear_hud()
    if M.gui then
        for _, p in ipairs(M.draw_ids) do
            if p[1] == 'text' then call(Gui.destroy_text, M.gui, p[2])
            elseif p[1] == 'triangle' then call(Gui.destroy_triangle, M.gui, p[2]) end
        end
    end
    M.draw_ids = {}
    M.draw_key = nil
end
local function surface_reset(worlds)
    -- Destroy the tracked texts while the gui handle is still usable, then the surface.
    clear_hud()
    -- By rendered value, and with a fresh wrapper: the stored handle is a dead wrapper.
    local here = live_world(worlds, M.gui_world_key)
    if M.gui and here then call(World.destroy_gui, here, M.gui) end
    M.draw_ids, M.gui, M.gui_world, M.gui_world_key, M.draw_key = {}, nil, nil, nil, nil
end

-- A finite ASCII bar.  Pure function of three numbers, so it is fully testable,
-- and it needs no material resource: a filled bar drawn with Gui.triangle would
-- require shipping a texture and a material, whereas the debug font is already
-- there (DRIVER HUD renders its text with the same font).  Clamped on both ends so
-- a negative or over-maximum reading cannot produce a broken bar.
local function bar_text(hp, max, width)
    width = width or 24
    if type(hp) ~= 'number' or type(max) ~= 'number' or max <= 0 then
        return string.rep('-', width)
    end
    local frac = hp / max
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local filled = math.floor(frac * width + 0.5)
    if filled < 0 then filled = 0 elseif filled > width then filled = width end
    return string.rep('=', filled) .. string.rep('-', width - filled)
end

-- The HUD shows the client-synchronised value, and says so.  It deliberately does not
-- pretend to be an exact HP: the exact value is host-side and is not in this process
-- (FINDINGS.md section 23), so a bar that showed a precise-looking number would be inventing
-- precision that does not exist.  The second line carries the wire value it came from
-- and the resolution limit, which is what makes the display honest and also useful.
local function hp_text(c)
    local max = c.max_health
    local hp = c.cur_health or max
    local pct = ''
    if type(hp) == 'number' and type(max) == 'number' and max > 0 then
        pct = string.format(' %.1f%%', hp / max * 100)
    end
    return string.format('HIVE LORD SYNC [%s] ~%d / %d%s',
        bar_text(hp, max, C.hud_bar_width), hp, max, pct)
end

local function hp_detail(c)
    local parts = {}
    if c.sync_k then parts[#parts + 1] = string.format('wire %d/63', c.sync_k) end
    if c.mask_value then parts[#parts + 1] = string.format('mask %d/16383', c.mask_value) end
    parts[#parts + 1] = string.format('+-%d', c.cur_step or 2381)
    parts[#parts + 1] = 'client-synced, not exact HP'
    return table.concat(parts, '   ')
end

-- Puts one reading on the surface, retiring whatever was there.  Factored out because the
-- HUD now has two things it can say (an identified reading, or a recognised-but-unreadable
-- candidate) and both must track the real text handles.
local function paint(txt, sub, w, h)
    clear_hud()
    local s = math.min(w / 1920, h / 1080) * C.hud_scale
    local x = w / 2 - 300 * s
    local y = C.hud_offset_y * s
    local a = math.floor(C.hud_alpha * 255)
    remember('text', call(Gui.text, M.gui, txt, 'core/performance_hud/debug', 20 * s,
        'core/performance_hud/debug', V2(x, y), Color(a, 255, 255, 255)))
    remember('text', call(Gui.text, M.gui, sub, 'core/performance_hud/debug', 14 * s,
        'core/performance_hud/debug', V2(x, y + 22 * s), Color(a, 190, 190, 190)))
    M.draw_key = txt .. '\n' .. sub
end

local function draw(w, h)
    local c = M.cal
    if c and c.identified then
        local txt, sub = hp_text(c), hp_detail(c)
        if txt .. '\n' .. sub ~= M.draw_key then paint(txt, sub, w, h) end
        return
    end

    -- Recognised but not readable.  An object holding the Hive Lord's 150000 maximum is
    -- worth naming even when there is no damage value to report: the reader can see it, and
    -- the only missing piece is the value that moves when it is damaged.  Four live dumps
    -- of the Hive Lord showed its field list with 46 OR 47 entries and the 150000 shifted
    -- by one between them, because the list is the entity's serialised component fields and
    -- its shape depends on what has been initialised -- so "holds 150000" is the part of
    -- the identity that survives, and a Hive Lord that has not been written to yet has no
    -- k/63 fraction at all.  Showing nothing in that state is indistinguishable from a
    -- broken mod, which is exactly how it read in play.
    local top = M.best and M.best[1]
    if top and (top.n150k or 0) >= 1 then
        local txt = string.format('HIVE LORD candidate  goid=%d  max 150000', top.id)
        local sub = string.format('fields=%d  no damage value yet -- damage it',
            top.fields)
        if txt .. '\n' .. sub ~= M.draw_key then paint(txt, sub, w, h) end
        return
    end

    -- Nothing recognised: make sure the screen is clear.
    clear_hud()
end

local function ensure_gui(worlds, world)
    if M.gui then return true end
    local main = world_key(world)
    for _, v in ipairs(worlds) do
        if world_key(v) ~= main then
            local g = call(World.create_screen_gui, v, 'scale', 1, 1)
            if g then
                M.gui_world, M.gui_world_key, M.gui = v, world_key(v), g
                return true
            end
        end
    end
    return false
end

-- -------------------------------------------------------------- update hook
-- The HUD runs on EVERY frame, including the frames where the search has nothing left to
-- do.  It used to sit at the end of update, behind three early returns, so the moment the
-- target or the session went away the HUD was never touched again: nothing redrew it and
-- nothing cleared it.  That is how the bar outlived the mission, and it could also sit
-- stale for the whole of a resweep.  Taking the surface down is part of this path, so it
-- cannot be conditional on having something to draw.
local function hud_tick(world)
    if not C.hud then return end
    local worlds = call(App.worlds) or {}
    -- The surface belongs to one of the worlds, and a mission change replaces them.  If
    -- the world that owns the surface is gone, the HUD is stranded on screen with no way
    -- to redraw or remove it.  Drop the surface and the reading the moment that happens.
    if M.gui then
        local here = live_world(worlds, M.gui_world_key)
        if not here then
            -- Capture the key first: surface_reset clears it, so logging afterwards
            -- printed "was nil" and told a reader nothing.
            local gone = tostring(M.gui_world_key)
            surface_reset(worlds)
            M.cal, M.last, M.draw_key = nil, nil, nil
            wf('HUD_SURFACE_DROPPED the world owning the HUD is gone (was %s)', gone)
        else
            -- Keep a usable wrapper: the one stored when the surface was created is a
            -- dead wrapper by the next frame.
            M.gui_world = here
        end
    end
    if not M.gui and not ensure_gui(worlds, world) then return end
    local w, h = call(Gui.resolution)

    -- If the HUD is on but nothing has been identified, say so in the conclusion and name
    -- the best candidate.  A live session ended with an empty screen while the conclusion
    -- talked about field reads: nothing anywhere told the reader that the HUD was on and
    -- simply had nothing to draw, which is indistinguishable from the mod having stopped
    -- drawing.  Errors keep the conclusion -- they outrank this.
    if not M.cal then
        local head = tostring(STATUS_HEAD)
        local is_error = head:find('ERROR', 1, true) ~= nil
        if not is_error then
            local top = M.best and M.best[1]
            local has_cand = top and (top.n150k or 0) >= 1
            local why = string.format(
                has_cand
                    and ('HUD is ON: showing a recognised Hive Lord candidate (%s) but no '
                         .. 'health value -- it holds the 150000 maximum and no synced '
                         .. 'damage fraction yet, which is the state of a Hive Lord that '
                         .. 'has not been written to (or damaged) yet.')
                    or ('HUD is ON and has nothing to draw: no Hive Lord identified yet. '
                        .. 'Top candidate %s. A Hive Lord is claimed only when an object '
                        .. 'holds the 150000 maximum TOGETHER with a synced damage '
                        .. 'fraction (k/63); a candidate with the maximum but no such '
                        .. 'field is shown as a candidate instead.'),
                top and string.format('goid=%d fields=%d [%s]', top.id, top.fields, top.magic)
                    or 'none yet')
            if why ~= M.hud_reason then
                M.hud_reason = why
                status_head(why)
            end
        end
    end

    if type(w) == 'number' and type(h) == 'number' and w > 0 and h > 0 then
        pcall(draw, w, h)
    end
end

local function search_frame(dt, ...)
    -- Test seam: a raised error inside this hook sets the global `failed` flag and
    -- the mod goes silent, so the offline suite must be able to prove that such an
    -- error actually reaches the log.  One table lookup per frame; nothing here
    -- runs unless the harness sets the global.
    if rawget(_G, '__HIVELORD_FAULT') then error('injected fault (test seam)') end
    M.frame = M.frame + 1
    local step = type(dt) == 'number' and dt or 0.016667
    if step < 0 then step = 0 elseif step > 0.25 then step = 0.25 end
    M.clock = M.clock + step

    local session = call(Net.game_session)
    local peer = call(Net.peer_id)
    local world = call(App.main_world)
    M.world = world
    -- Compare the engine handles by their *rendered* value, never by identity.
    -- The live log proved why: `Net.game_session()` / `App.main_world()` hand back
    -- a fresh wrapper on every call, so `session ~= M.session` was true every
    -- single frame, the reset below fired continuously, and the object sweep was
    -- restarted from id 1 forever (it never got past 903 and found nothing).
    -- tostring() renders the handle's content ("[GameSession]", "[World]"), which
    -- is stable; a real session or peer change still differs.
    local key = tostring(session) .. '|' .. tostring(peer)
    if key ~= M.session_key then
        wf('SESSION_CHANGE session=%s peer=%s world=%s key=%s', tostring(session),
            tostring(peer), tostring(world), key)
        M.session_key = key
        surface_reset(call(App.worlds) or {})
        M.census, M.probed, M.probe_list, M.probe_index, M.probes = {}, {}, {}, 1, 0
        M.known, M.diag_done = {}, false
        M.prev_census_n, M.resweep_backoff = 0, 1
        M.sweeping = false
        M.best, M.weak, M.weak_list, M.dumped_w, M.samples = {}, {}, {}, 0, 0
        M.hist, M.hist_count, M.cal, M.last = {}, 0, nil, nil
        M.next_resweep = 0
        M.owned_seen = 0
    end
    M.peer_scalar = peer
    if not session then return end
    if call(GS.in_session, session) == false then
        M.was_in_session = false
        return
    end
    if M.was_in_session == false then
        -- A genuine mission entry: the world changed even though the handles'
        -- rendered values did not.
        wf('MISSION_ENTER (in_session false -> true)')
        M.census, M.probed, M.probe_list, M.probe_index, M.probes = {}, {}, {}, 1, 0
        M.known, M.diag_done = {}, false
        M.prev_census_n, M.resweep_backoff = 0, 1
        M.sweeping = false
        M.goid, M.watch_goid, M.watch_score = nil, nil, nil
        M.hist, M.hist_count, M.cal, M.last = {}, 0, nil, nil
        M.best, M.weak, M.weak_list, M.dumped_w, M.samples = {}, {}, {}, 0, 0
        M.next_resweep = 0
    end
    M.was_in_session = true

    local owned = call(GS.objects_owned_by, session, peer)
    local owned_n = type(owned) == 'table' and #owned or 0
    M.owned_seen = owned_n
    -- `objects_owned_by` is a hint, not a gate.  A live session logged
    -- MISSION_ENTER three times while owning zero objects, so gating on it meant
    -- the census never ran and that whole session learned nothing.  The census is
    -- the honest test of "is there a world with entities", and a census that finds
    -- nothing costs only cheap game_object_exists calls.
    if C.in_mission_only and owned_n == 0 then
        if not M.owned_zero_logged then
            M.owned_zero_logged = true
            wf('OWNED_ZERO objects_owned_by returned nothing; the census will decide')
            status('objects_owned_by returned nothing; relying on the census')
        end
    else
        M.owned_zero_logged = false
    end

    -- Diagnostics are driven from the frame loop, not from inside the probe: the
    -- probe stops once a strong match is pinned, and the ownership picture can
    -- change after that (empty during load, populated once a mission starts), so a
    -- verdict computed once would be about the wrong world.  The signature is
    -- deliberately coarse so this cannot turn into a per-frame flood.
    if M.diag_wanted and session then
        local sig = string.format('%d:%d:%d', math.floor(M.probes / 128),
            M.owned_seen or 0, M.goid and 1 or 0)
        if sig ~= (M.diag_sig or '') then
            M.diag_sig = sig
            land_census()
            pcall(run_diagnostics, session, M.peer_scalar)
        end
    end

    -- Fast path: a Hive Lord already pinned in a previous run.
    if not M.goid then
        local saved = load_state()
        if saved.goid and saved.goid > 0
            and call(GS.game_object_exists, session, saved.goid) == true then
            M.goid = saved.goid
            wf('RESUME goid=%d from state file', M.goid)
        end
    end

    -- Census and probe run whether or not a target is already pinned.  Gating both on
    -- `not M.goid` meant the moment the Hive Lord was identified the whole search froze:
    -- no further object shapes were recorded, the samples file was never written, and a
    -- target that died and was replaced inside the same mission would never be noticed.
    -- Looking must not stop because something was found.
    if C.sweep and not M.sweeping and M.clock >= M.next_resweep then
        M.next_resweep = M.clock + C.resweep_seconds * (M.resweep_backoff or 1)
        start_census()
    end
    if M.sweeping then
        advance_census(session)
        -- With a target pinned the watch keeps running while the census walks: a sweep
        -- takes a few seconds and would otherwise starve the HP readout in bursts.
        if not M.goid then return end
    end
    if M.frame > C.probe_delay then advance_probe(session) end

    if not M.goid then
        -- Keep sweeping for a strong match, but once a weak candidate is being
        -- watched, do not return: the watch is the thing that answers the question.
        if not M.watch_goid then return end
        if M.clock >= M.next_watch then
            M.next_watch = M.clock + C.watch_seconds
            pcall(read_once, session)
        end
        if M.clock >= M.next_read then
            M.next_read = M.clock + C.read_seconds
            pcall(report)
        end
        return
    end

    if M.clock >= M.next_watch then
        M.next_watch = M.clock + C.watch_seconds
        -- Never swallow this silently.  A raise inside read_once leaves the previous
        -- calibration in place, so the HUD keeps showing a stale, plausible-looking
        -- number -- which is worse than showing nothing.  Cost: one string compare on
        -- the success path.
        local ok, err = pcall(read_once, session)
        if not ok then
            wf('READ_ERROR %s', tostring(err))
            status_head('READ_ERROR: ' .. tostring(err))
        end
    end
    if M.clock >= M.next_read then
        M.next_read = M.clock + C.read_seconds
        local ok, err = pcall(report)
        if not ok then
            wf('REPORT_ERROR %s', tostring(err))
            status_head('REPORT_ERROR: ' .. tostring(err))
        end
    end
end

-- ONE call site, on every frame, whatever the search above decided to do.  The HUD used
-- to be serviced from three points inside the search, behind its early returns, so any
-- path that returned early also stopped maintaining the surface -- which is how the bar
-- outlived the mission, and how it could sit stale through a whole resweep.  Splitting
-- the two responsibilities means a search path can no longer skip the HUD at all.
local function update(dt, ...)
    search_frame(dt, ...)
    return hud_tick(M.world)
end

local old = rawget(_G, 'update')
if type(old) ~= 'function' then
    return { installed = false, reason = 'no global update to chain' }
end
rawset(_G, '__HIVELORD_HP_INSTALLED', true)
local failed = false
rawset(_G, 'update', function(...)
    if not failed then
        local ok, err = pcall(update, ...)
        if not ok then
            failed = true
            wf('LUA_ERROR %s', tostring(err))
            status_head('LUA_ERROR: ' .. tostring(err))
        end
    end
    return old(...)
end)
local stop = rawget(_G, 'shutdown')
rawset(_G, 'shutdown', function(...)
    pcall(surface_reset, call(App.worlds) or {})
    if type(stop) == 'function' then return stop(...) end
end)
status_head('armed; waiting for a mission')

-- Test seam.  The bar's rounding and clamping are pure properties of three
-- numbers, and driving them through a live entity cannot exercise them: the
-- calibration only ever tracks *decreases*, so an over-heal never reaches the
-- renderer.  Exposing the pure helpers is how the offline suite asserts them
-- exactly.  Nothing here runs unless the harness sets the global, and the addon
-- touches it nowhere else.
if rawget(_G, '__HIVELORD_EXPOSE_PURE') then
    _G.__HIVELORD_PURE = { bar_text = bar_text, calibrate = calibrate,
                           is_k63 = is_k63, mask_of = mask_of,
                           hp_text = hp_text, hp_detail = hp_detail,
                           status = status, status_head = status_head,
                           track_candidate = track_candidate }
end
return { installed = true }
